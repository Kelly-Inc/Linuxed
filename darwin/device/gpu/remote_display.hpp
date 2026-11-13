// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include "../input/vnc/vnc_input.hpp"

#include <cstdint>
#include <memory>

namespace uml::gpu {

/* The guest's display served over VNC on loopback, beside the device's own
 * view of it: a computer reaches it through the USB tunnel (`iproxy 5900
 * 5900`) and drives the guest with its keyboard and mouse.
 *
 * Frames come from the frame mirror (frame_tap.hpp), which this takes while it
 * runs, so Picture in Picture and a remote display do not run together. Only
 * the 64-pixel tiles a frame changed are sent, and the server's own thread is
 * the only one that touches what it sends. Input reaches the guest through
 * `inputSink` as the VNC tablet and keyboard events of vnc_input.hpp. */
class RemoteDisplay final {
public:
    struct Options {
        std::uint16_t port {5900};
        /* The widest frame served; a larger guest display is scaled down. */
        std::uint32_t maximumWidth {1920};
        std::uint32_t framesPerSecond {60};
    };

    /* Throws std::runtime_error when the server cannot listen. */
    RemoteDisplay(Options options, uml::input::vnc::VncInputSink inputSink);
    ~RemoteDisplay();

    RemoteDisplay(const RemoteDisplay&) = delete;
    RemoteDisplay& operator=(const RemoteDisplay&) = delete;

private:
    struct State;
    std::unique_ptr<State> state_;
};

} // namespace uml::gpu
