# ADR-0004: PiP is a detachable mini-window, not AVPictureInPictureController

**Status:** Accepted

Native PiP requires SampleBuffer rendering that mpv's render API does not
expose. `PipService` therefore models PiP as a detachable floating window
hosting the same Metal viewport; the HUD label matches this honestly.
Revisit if mpv gains a sample-buffer output.
