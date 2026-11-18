# Trolldroid

Trolldroid is the Android application: Kernarium's Andarium at the commit
[`upstream.env`](upstream.env) pins, with the Android kernel and LineageOS
release that commit accepts. [`apply.py`](apply.py) changes that checkout;
every edit must match exactly, so a new pin fails until the edits are updated.

What Trolldroid adds:

- **Images.** Several Android images, each in `Library/Guests/<name>/` with its
  own data, optional installed system and backups
  ([`app/TrolldroidSlots.swift`](app/TrolldroidSlots.swift)). An image without
  an installed system boots the release the application carries.
- **Recovery.** The launch screen ([`app/RecoveryView.swift`](app/RecoveryView.swift))
  installs an extracted release folder, wipes, backs up and restores an
  image, adds and deletes images, and boots the chosen one. A destructive step
  needs a full swipe. Another image needs the application to be opened again.
- **Name and icon.** The display name, bundle identifier and
  [`icon/AppIcon.png`](icon/AppIcon.png). An ignored `icon/AppIcon.local.png`
  replaces the icon in a local build.

The image ships no Google software. `.github/workflows/trolldroid-ipa.yml`
builds the unsigned `.ipa`.
