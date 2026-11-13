// SPDX-License-Identifier: GPL-2.0-or-later
#include "remote_display.hpp"

#include "frame_tap.hpp"

#include <CoreVideo/CoreVideo.h>
#include <arpa/inet.h>
#include <rfb/rfb.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <mutex>
#include <span>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace uml::gpu {

namespace vnc_input = uml::input::vnc;

namespace {

constexpr std::uint32_t tileSize = 64;

} // namespace

struct RemoteDisplay::State {
    Options options;
    vnc_input::VncInputSink inputSink;
    rfbScreenInfoPtr screen {};
    std::thread eventThread;
    std::atomic<bool> running {true};

    /* The newest mirrored frame, handed from the mirror's thread. */
    std::mutex pendingMutex;
    std::vector<std::uint32_t> pending;
    std::uint32_t pendingWidth {};
    std::uint32_t pendingHeight {};
    bool pendingFresh {};

    /* What the server sends; only the event thread touches it. */
    std::vector<std::uint32_t> framebuffer;
    std::uint32_t width {};
    std::uint32_t height {};
    int lastButtons {};

    static void receiveFrame(void* context, void* pixelBuffer) noexcept
    {
        auto* state = static_cast<State*>(context);
        auto* buffer = static_cast<CVPixelBufferRef>(pixelBuffer);
        if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) !=
            kCVReturnSuccess)
            return;
        const auto frameWidth =
            static_cast<std::uint32_t>(CVPixelBufferGetWidth(buffer));
        const auto frameHeight =
            static_cast<std::uint32_t>(CVPixelBufferGetHeight(buffer));
        const auto rowBytes = CVPixelBufferGetBytesPerRow(buffer);
        const auto* base =
            static_cast<const std::uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
        if (base != nullptr && frameWidth != 0 && frameHeight != 0) {
            std::lock_guard lock(state->pendingMutex);
            state->pending.resize(
                static_cast<std::size_t>(frameWidth) * frameHeight);
            // BGRA bytes are the server format's 0xAARRGGBB words.
            for (std::uint32_t row = 0; row < frameHeight; ++row)
                std::memcpy(
                    state->pending.data() +
                        static_cast<std::size_t>(row) * frameWidth,
                    base + row * rowBytes,
                    static_cast<std::size_t>(frameWidth) * 4U);
            state->pendingWidth = frameWidth;
            state->pendingHeight = frameHeight;
            state->pendingFresh = true;
        }
        CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    }

    void setFormat() noexcept
    {
        screen->serverFormat.bitsPerPixel = 32;
        screen->serverFormat.depth = 24;
        screen->serverFormat.bigEndian = FALSE;
        screen->serverFormat.trueColour = TRUE;
        screen->serverFormat.redMax = 255;
        screen->serverFormat.greenMax = 255;
        screen->serverFormat.blueMax = 255;
        screen->serverFormat.redShift = 16;
        screen->serverFormat.greenShift = 8;
        screen->serverFormat.blueShift = 0;
    }

    /* Takes the newest frame into what is sent, marking only changed tiles. */
    void publishPending()
    {
        std::lock_guard lock(pendingMutex);
        if (!pendingFresh)
            return;
        pendingFresh = false;
        if (pendingWidth != width || pendingHeight != height) {
            width = pendingWidth;
            height = pendingHeight;
            framebuffer = pending;
            rfbNewFramebuffer(screen,
                reinterpret_cast<char*>(framebuffer.data()),
                static_cast<int>(width), static_cast<int>(height), 8, 3, 4);
            setFormat();
            rfbMarkRectAsModified(screen, 0, 0,
                static_cast<int>(width), static_cast<int>(height));
            return;
        }
        for (std::uint32_t top = 0; top < height; top += tileSize) {
            const auto bottom = std::min(top + tileSize, height);
            for (std::uint32_t left = 0; left < width; left += tileSize) {
                const auto right = std::min(left + tileSize, width);
                const auto bytes = static_cast<std::size_t>(right - left) * 4U;
                bool changed = false;
                for (auto row = top; row < bottom; ++row) {
                    const auto offset =
                        static_cast<std::size_t>(row) * width + left;
                    if (std::memcmp(&framebuffer[offset], &pending[offset],
                            bytes) != 0) {
                        changed = true;
                        std::memcpy(&framebuffer[offset], &pending[offset], bytes);
                    }
                }
                if (changed)
                    rfbMarkRectAsModified(screen, static_cast<int>(left),
                        static_cast<int>(top), static_cast<int>(right),
                        static_cast<int>(bottom));
            }
        }
    }

    void deliver(std::span<const vnc_input::VncInputEvent> events) noexcept
    {
        (void)vnc_input::tryDeliver(inputSink, events);
    }

    void handlePointer(int buttons, int x, int y) noexcept
    {
        if (width == 0 || height == 0)
            return;
        const auto coordinate = [](double position, double extent) {
            return vnc_input::normalizedAbsoluteCoordinate(
                (position + 0.5) / extent, 1.0);
        };
        std::array<vnc_input::VncInputEvent, 9> events {};
        std::size_t count = 0;
        const auto append = [&](std::uint16_t type, std::uint16_t code,
                                std::int32_t value) {
            events[count++] = {.type = type, .code = code, .value = value};
        };
        append(vnc_input::eventAbsolute, vnc_input::absoluteX,
            coordinate(x, width));
        append(vnc_input::eventAbsolute, vnc_input::absoluteY,
            coordinate(y, height));
        append(vnc_input::eventKey, vnc_input::buttonLeft, buttons & 1);
        append(vnc_input::eventKey, vnc_input::buttonMiddle, (buttons >> 1) & 1);
        append(vnc_input::eventKey, vnc_input::buttonRight, (buttons >> 2) & 1);
        // Wheel "buttons" press and release in one event each notch.
        const int pressed = buttons & ~lastButtons;
        if ((pressed & 8) != 0)
            append(vnc_input::eventRelative, vnc_input::relativeWheel, 1);
        if ((pressed & 16) != 0)
            append(vnc_input::eventRelative, vnc_input::relativeWheel, -1);
        if ((pressed & 32) != 0)
            append(vnc_input::eventRelative,
                vnc_input::relativeHorizontalWheel, -1);
        if ((pressed & 64) != 0)
            append(vnc_input::eventRelative,
                vnc_input::relativeHorizontalWheel, 1);
        lastButtons = buttons;
        append(vnc_input::eventSync, vnc_input::syncReport, 0);
        deliver(std::span(events).first(count));
    }

    void handleKey(bool down, rfbKeySym symbol) noexcept
    {
        const auto code = vnc_input::keyCode(symbol);
        if (!code)
            return;
        const std::array events {
            vnc_input::VncInputEvent {
                .type = vnc_input::eventKey, .code = *code,
                .value = down ? 1 : 0},
            vnc_input::VncInputEvent {
                .type = vnc_input::eventSync, .code = vnc_input::syncReport,
                .value = 0},
        };
        deliver(events);
    }

    void eventLoop()
    {
        while (running.load(std::memory_order_acquire) && rfbIsActive(screen)) {
            publishPending();
            rfbProcessEvents(screen, 4000);
        }
    }
};

RemoteDisplay::RemoteDisplay(
    Options options,
    vnc_input::VncInputSink inputSink)
    : state_(std::make_unique<State>())
{
    auto& state = *state_;
    state.options = options;
    state.inputSink = std::move(inputSink);
    // A placeholder frame until the mirror delivers the guest's own.
    state.width = 16;
    state.height = 16;
    state.framebuffer.assign(static_cast<std::size_t>(16) * 16, 0);
    int argumentCount = 0;
    state.screen = rfbGetScreen(&argumentCount, nullptr, 16, 16, 8, 3, 4);
    if (state.screen == nullptr)
        throw std::runtime_error("rfbGetScreen failed");
    auto* screen = state.screen;
    screen->desktopName = "Linuxed";
    screen->frameBuffer = reinterpret_cast<char*>(state.framebuffer.data());
    screen->screenData = &state;
    screen->alwaysShared = TRUE;
    screen->port = options.port;
    screen->ipv6port = -1;
    // Loopback only: the USB tunnel is the way in, never the network.
    in_addr loopback {};
    (void)inet_pton(AF_INET, "127.0.0.1", &loopback);
    screen->listenInterface = loopback.s_addr;
    screen->kbdAddEvent = [](rfbBool down, rfbKeySym symbol,
                              rfbClientPtr client) noexcept {
        static_cast<State*>(client->screen->screenData)
            ->handleKey(down != FALSE, symbol);
    };
    screen->ptrAddEvent = [](int buttons, int x, int y,
                              rfbClientPtr client) noexcept {
        rfbDefaultPtrAddEvent(buttons, x, y, client);
        static_cast<State*>(client->screen->screenData)
            ->handlePointer(buttons, x, y);
    };
    state.setFormat();
    rfbInitServer(screen);
    if (!rfbIsActive(screen) || screen->listenSock == RFB_INVALID_SOCKET) {
        rfbScreenCleanup(screen);
        state.screen = nullptr;
        throw std::runtime_error("the remote display could not listen");
    }
    setFrameTap(&State::receiveFrame, &state,
        {.maximumWidth = options.maximumWidth,
         .framesPerSecond = options.framesPerSecond});
    state.eventThread = std::thread(&State::eventLoop, &state);
}

RemoteDisplay::~RemoteDisplay()
{
    // No mirror call runs or starts once this returns.
    setFrameTap(nullptr, nullptr);
    state_->running.store(false, std::memory_order_release);
    if (state_->eventThread.joinable())
        state_->eventThread.join();
    if (state_->screen != nullptr) {
        rfbShutdownServer(state_->screen, TRUE);
        rfbScreenCleanup(state_->screen);
    }
}

} // namespace uml::gpu
