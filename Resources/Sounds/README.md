# Sound asset provenance

Source mapping supplied by the project owner; local files and source pages
checked on 2026-09-16. Actual download dates were not supplied. Local file
validation does not establish a byte-for-byte match with remote downloads.

All nine MP3 recordings are listed under the **Pixabay Content License**, not
CC0 on those download pages. An original CC0 source was subsequently verified
for `coin/chime.mp3`: [coin clatter 6.wav by FenrirFangs](https://freesound.org/people/FenrirFangs/sounds/213984/).
The local processed MP3 has not been compared byte-for-byte with that original.
See the [license summary](https://pixabay.com/service/license-summary/)
and [full terms](https://pixabay.com/service/terms/). Attribution is optional,
but credits are retained here. Audio assets do not inherit the source-code
license. The terms prohibit standalone distribution: review public-repository
distribution of original recordings separately from integrated application use.

## Distribution policy

Raw audio files are local-only and excluded from Git tracking. This document
retains the source/credit/license records. Commercial application builds may
bundle the recordings as functional interface cues, not as a downloadable sound
library. This is our interpretation of integrated use under the license, not a
guarantee that all additional third-party rights have been cleared.

For a fresh checkout, manually download the nine recordings from the links
below, place them at the listed paths, and prepare them as described below.
The macOS Xcode project copies the local `Resources/Sounds` folder into the app;
Git ignore rules do not prevent local resource bundling. Do not upload raw sounds
as repository files or standalone release attachments. Back up local assets
separately: they cannot be restored from a fresh Git checkout.

Removing tracked files from the current tree does not remove earlier copies
from Git history. History cleanup, if required, must be handled separately.

Paths are relative to this directory.

| File | Creator / credit | Source |
|---|---|---|
| `droplet/chime.mp3` | Mrstokes302 | [Water Droplet SFX](https://pixabay.com/sound-effects/film-special-effects-water-droplet-sfx-mrstokes302-530199/) |
| `droplet/coin.mp3` | floraphonic | [Water Droplet 2](https://pixabay.com/sound-effects/film-special-effects-water-droplet-2-165634/) |
| `droplet/coins.mp3` | floraphonic | [Water Droplet 6](https://pixabay.com/sound-effects/film-special-effects-water-droplet-6-165636/) |
| `coin/coin.mp3` | freesound_gamestudio | [Drop Coin](https://pixabay.com/sound-effects/film-special-effects-drop-coin-384921/) |
| `coin/coins.mp3` | Universfield | [Coin Drop](https://pixabay.com/sound-effects/film-special-effects-coin-drop-229314/) |
| `coin/chime.mp3` | FenrirFangs (Freesound); uploader freesound_community | [Coin Clatter 6](https://pixabay.com/sound-effects/film-special-effects-coin-clatter-6-87110/) |
| `register/coin.mp3` | DRAGON-STUDIO | [Cash Register Kaching](https://pixabay.com/sound-effects/film-special-effects-cash-register-kaching-376867/) |
| `register/coins.mp3` | Universfield | [Cash Register Open](https://pixabay.com/sound-effects/film-special-effects-cash-register-open-567194/) |
| `register/chime.mp3` | Universfield | [Cash Register Open Ding](https://pixabay.com/sound-effects/film-special-effects-cash-register-open-ding-559401/) |

The resolver prefers MP3 over WAV within each pack. With all nine MP3s present,
the seven existing synthesized WAVs are unused temporary fallbacks:
`coin/chime.wav`, `droplet/*.wav`, and `register/*.wav`.

## Playback preparation (2026-09-16)

All nine MP3s were decoded, trimmed only at their beginning/end, and re-encoded
with libmp3lame VBR quality 2. Silence detection used -55 dB for at least 30 ms;
20 ms before the detected onset and 50 ms after the final audible boundary were
retained where available. Internal pauses were preserved. This threshold-based
preparation still requires listening approval for natural decay and onset.

Original files had no author/copyright/title tags reported by ffprobe.
Source metadata and embedded artwork are excluded from processed files; ID3v1
and ID3v2 writing are disabled. Technical encoder information may remain in the
MP3 Xing/LAME header, which supports correct duration and encoder-delay handling.
These edits do not change the original license or establish redistribution rights.

| File | Prepared duration |
|---|---|
| `coin/chime.mp3` | 3.099 s |
| `coin/coin.mp3` | 0.723 s |
| `coin/coins.mp3` | 1.046 s |
| `droplet/chime.mp3` | 1.980 s |
| `droplet/coin.mp3` | 0.307 s |
| `droplet/coins.mp3` | 0.455 s |
| `register/chime.mp3` | 1.810 s |
| `register/coin.mp3` | 1.037 s |
| `register/coins.mp3` | 1.709 s |

The generated WAV files use only mathematical oscillators, exponential
envelopes, and deterministic pseudo-random noise. They do not embed or sample
third-party recordings.

Do not infer CC0 status from a filename or download site category alone.
