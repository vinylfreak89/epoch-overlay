# Spike 03 — FSKit health on macOS 26.6.1 (tier-2 engine viability)

Date: 2026-08-29. Machine: macOS 26.6.1 (25G76), Xcode 26.6, regular user.
Artifacts: `HealthFS.swift` (minimal path-backed read-only module),
`build.sh` (hand-assembled bundle, no Xcode), `xcode/` (project for real
signing).

## Question

Can a third-party, path-backed (`FSPathURLResource`) FSKit module be
registered, enabled, and mounted by an unprivileged user on this machine —
i.e., is FSKit a viable tier-2 covering-mount engine, and what exactly
gates it?

## What happened, step by step

1. **Build**: minimal `FSUnaryFileSystem` + read-only `FSVolume` (one
   `HEALTH.txt`) compiles against the 26.6 SDK with plain `swiftc`; bundle
   hand-assembled (app + `Contents/Extensions/*.appex`), no Xcode project
   needed. Swift API notes: `FSItemAttributes`→`FSItem.Attributes`,
   `FSVolumeIdentifier`→`FSVolume.Identifier`.
2. **Registration**: ad-hoc-signed appex registers with pluginkit under
   `com.apple.fskit.fsmodule` from `~/Applications`. ✓
3. **Enablement gate**: `mount -F -t healthfs` initially fails with
   `Module … is disabled!` — the per-user ExtensionKit approval. The
   System Settings toggle (General → Login Items & Extensions → File
   System Extensions) worked; `pluginkit -e use` alone does not satisfy
   fskitd. ✓ by design
4. **Launch gate — the real finding**: after enablement, mount fails with
   `Probing resource: … com.apple.extensionKit.errorDomain error 2`. Direct
   exec of the appex binary: **SIGKILL (exit 137)**. Re-signed *without*
   `com.apple.developer.fskit.fsmodule`: binary launches normally (exits
   with ExtensionFoundation's expected "not in host context" trap). So
   AMFI kills any ad-hoc-signed binary carrying the restricted fsmodule
   entitlement. No boot-security involvement.
5. **Signing path**: hand-written Xcode project (application +
   `com.apple.product-type.extensionkit-extension` targets, automatic
   signing) builds unsigned; embedding requires the extension's bundle id
   to be prefixed by the host app's. With a **free personal team**, Xcode
   refuses at profile creation:

   > Cannot create a Mac App Development provisioning profile for
   > "com.epoch-overlay.healthfs.module". Personal development teams,
   > including "Aaron DeBruin", do not support the FSKit Module capability.

## Verdicts

| question | verdict |
|---|---|
| fskitd unprivileged-client bug (26.1/26.2, killed loaf) | **absent on 26.6.1** — fskitd converses normally with an unprivileged mount(8) client |
| path-backed module registration/enablement pipeline | **works** (pluginkit + Settings toggle) |
| ad-hoc / unsigned development | **impossible** — restricted entitlement, AMFI SIGKILL |
| free Apple ID (personal team) | **impossible** — FSKit Module capability not offered |
| paid Apple Developer Program ($99/yr) | untested here, but it is the documented tier for the capability; no other gate remains between it and a mount attempt |

## Consequence for DESIGN.md

Tier 1 is unaffected (needs no FSKit). For tier 2, the FSKit engine is
technically healthy on this OS but **costs a paid Apple Developer Program
membership** to develop at all. Without paying: fuse-t (vendor-signed,
kext-less, no developer account needed to *use*) or the thin-VM engine are
the tier-2 engines available at zero account cost. If the membership is
ever acquired, this spike's project is the ready-made starting point — the
next unknown in line is mount behavior and per-op throughput, with no
known gate in front of it.
