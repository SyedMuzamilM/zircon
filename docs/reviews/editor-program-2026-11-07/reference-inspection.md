# Installed Zed Preview inspection

Observed November 7, Zed Preview 1.28.0 build 20261104.153513. Executable SHA-256 `cd4b698951d19995b4d12b7b0cfc1b4dbb1ec2dc7196e75689e48434cb9ef637` matches the November 6 reference exactly. The clean reference screenshots in `../zed-ui/evidence/` therefore depict the same shipped binary, but remain dated historical observations.

Launched a separate process using `ZED_STATELESS=1` and the owned `/tmp/zircon-ui-review/zeddata-isolated` profile with the disposable `EditorReview` project. A fresh exact-window capture shows Zed's project trust dialog. This PNG is evidence of that dialog, not a valid clean-editor visual comparison. Actual window size was 1470 × 923 logical pixels, not the desired matched dimensions.

The earlier Swift automation helper failed to obtain an AX window for the new instance. Sending a Return CGEvent to that PID did not dismiss the trust dialog. No interaction or matched-size verification is claimed. No permission prompt, personal Zed preference, personal project, account or global trust setting was changed. The owned reference process was terminated after capture; its helper was its descendant. Personal Zed processes were left alone.

Use the earlier unobscured reference images for inspiration with their documented capture limits. Re-establish controlled native interaction before claiming fresh matched workflow screenshots or complete visual parity.
