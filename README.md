![enter image description here](https://files.catbox.moe/cidjje.png)
![enter image description here](https://files.catbox.moe/2l29rz.png)
![enter image description here](https://files.catbox.moe/y3g65i.png)
![enter image description here](https://files.catbox.moe/7bieve.png)
![enter image description here](https://files.catbox.moe/e87f39.png)

# English Subtitles Generator, Cut & Join Videos

Three tools for movies on your Mac, in one small app: **English subtitles** for foreign-language films, a frame-exact **Cutter/Splitter**, and a **Joiner**. They're described below, subtitles first.

A small macOS app: **drop a foreign-language movie (.mp4, .mkv, …) on it and get English subtitles** (`Movie.srt`) saved next to the movie. VLC picks them up automatically. If a `Movie.srt` already exists, it is kept as `Movie.srt.bak`.

The speech recognition and translation run on [Groq](https://groq.com)'s free Whisper API (`whisper-large-v3`), so it's fast even on an older Mac. A 2-hour film takes **about 15 minutes**: that pace is set by the free tier's limit of 20 requests a minute. The log shows an estimate when a job starts.

- Runs on **macOS 12 Monterey or later** and is built for **Intel Macs** (it also runs on Apple Silicon through Rosetta).
- **Free**: needs only a free Groq account. Nothing is installed besides the app, which bundles its own ffmpeg.
- Shows a live progress bar and a log. Every failure has an **error code** (see the table below).

## How it works

1. **Read the file.** ffmpeg lists the audio tracks. If there are several, the app picks the first one *not* tagged English, so it skips English dubs.
2. **Extract the audio** as mono, 16 kHz MP3 (what Whisper uses internally). On 5.1/7.1 tracks it keeps only the centre channel, where film dialogue is mixed, which cuts out music and effects.
3. **Split the audio into parts of 30 seconds or less**, cut at the quietest moment between phrases (measured every 0.1 s, so it works even over background music). Whisper listens in 30-second windows. On longer files it uses its own guessed timestamps to decide where the next window starts, and when translating (especially Telugu, Tamil and similar languages) those guesses go wrong: speech is skipped and subtitles drift out of sync after the first 30 seconds. One window per part avoids that. Silent parts are not uploaded at all.
4. **Upload each part** to Groq's `/audio/translations` endpoint. Whisper transcribes and translates to English in one step and returns the text with timestamps.
5. **Keep it English.** If a part comes back mostly in another language (Whisper sometimes mistakes the language of a short part, e.g. Korean for Chinese or Japanese), it is asked again once with an English-only hint. Leftover non-English words are removed from mixed lines, lines that repeat themselves are collapsed, and common filler ("Welcome to my channel") is dropped. Requests also ask Groq for English output (`language=en`) if Groq accepts it.
6. **Build the SRT.** It shifts timestamps to film time, removes known Whisper "hallucinations" (such as "Thanks for watching!" over music), merges repeats, splits long lines (max 2 lines × 42 characters), and caps how long a short line stays on screen.

Finished parts are remembered, so if a job is interrupted (daily limit, Wi-Fi drop, quitting the app), drop the same file again and it continues where it stopped.

## Groq free-tier limits

As published by Groq when this was written; they may change:

| Limit | Value | What it means |
|---|---|---|
| Audio per hour | 7,200 s (2 h) | About one feature film per hour. If a film is longer, the app **waits automatically** (it shows a countdown) until Groq frees up capacity, then continues. |
| Audio per day | 28,800 s (8 h) | About 3–4 films a day. |
| File size | 25 MB | The app's parts are under 0.3 MB. |
| Requests per minute | 20 | The app sends at most one request every 3.1 s to stay under this; it sets the ~15 min per 2-hour film. |
| Requests per day | 2,000 | About 250 requests per 2-hour film, so the audio limit above is reached first. |

## Cutter and Joiner

Two more tabs use the bundled ffmpeg to cut and join videos **without changing their quality**.

**Cutter:** drop a video, pick a start time and either an end time or a length ("from 00:20:00, 00:02:00 long") from the hours : minutes : seconds · frame dropdowns. They only offer times inside the video (hours are greyed out for videos under an hour), and the frame dropdown picks an exact frame within the second. End and length start at zero: **To end** fills in the video's last point, and in Duration mode tiny presets (5s … 5m) set common lengths. Right-click the dropdowns to copy or paste a time. Stills of the first and last frame show exactly what you will get. Optionally split the cut **into N equal parts** or **into parts of a fixed length** (the last part may be shorter). Results are saved next to the original, e.g. `Movie [00.20.00–00.22.00].mkv` or `Movie [00.20.00–00.22.00] part 1 of 4.mkv`.

**Joiner:** drop one or more videos. Each piece is either the **whole file** or a **cut** of it; the ⧉ button adds another cut from the same file. Files dropped together are added in natural name order ("part 2" before "part 10"). Re-sort the list any time by **Name (natural)**, **Date modified** or **Duration** (the ↑/↓ button flips the direction), or reorder pieces by dragging or with the arrows; they are joined in the order shown into `Joined <date> <time>.<ext>` next to the first file.

**How the quality is kept (smart cut):** a video can only be cut cleanly at keyframes (every few seconds). For H.264 videos the app copies everything between the first and last keyframe of each piece **bit for bit**, and re-encodes only the few frames before the first and after the last keyframe at very high quality. Cuts are exact to the frame, and more than 95% of the video is usually untouched. Audio and subtitle tracks are copied unchanged (all of them, with their languages), and chapters and the title are kept and adjusted.

- Other codecs (e.g. HEVC/H.265): the cut video is re-encoded at high quality with the same codec; audio and subtitles are still copied. This is slower (roughly real time or longer on an older Mac).
- Joining videos of **different formats** (size, frame rate, codec): they must be converted to one format. By default the app picks the format that makes up **most of the running time**, so the least video is converted; a "Match" menu lets you choose another. Converted joins keep the first audio track only and leave out subtitles.
- After a smart cut, the app decodes the frames around every join to check them; if anything is wrong it redoes the job with full re-encoding automatically.
- Temporary files need about as much free space as the result.

## Long films

A 3-hour film is about 390 parts. The first 2 hours of audio go through at full speed (about 13 minutes). Then Groq's hourly limit (2 hours of audio per hour) kicks in: the app waits, with a countdown in the window, and continues on its own as capacity frees up. **Expect roughly 45–75 minutes in total**, with nothing to do on your side. Two 3-hour films fit in one day's free allowance.

## Install (first time)

1. **Download** `EnglishSubtitlesGenerator-CutJoinVideos-macOS.zip`:
   - From the repository's **Releases** page, if a release exists, or
   - From **Actions → latest "Build" run → Artifacts**. Artifacts arrive as a zip that contains the zip; unzip both.
2. Unzip, and drag **English Subtitles Generator, Cut & Join Videos.app** into **Applications**.
3. The app isn't notarised by Apple (that needs a paid developer account), so macOS blocks it the first time. Either:
   - **Right-click** the app → **Open** → **Open**, or
   - In Terminal, run:
     ```
     xattr -dr com.apple.quarantine "/Applications/English Subtitles Generator, Cut & Join Videos.app"
     ```
4. **Get a free Groq API key**:
   1. Go to [console.groq.com/keys](https://console.groq.com/keys) and sign in with Google or email.
   2. Click **Create API Key** and copy the key (it starts with `gsk_`).
   3. Paste it into the box at the top of the app and click **Save**. The app checks the key with Groq straight away.

   The key is stored in `~/Library/Application Support/EnglishSubtitleMaker/groq-api-key`, readable only by your user account.

## Use

- **Several audio tracks** (e.g. original + English dub): the app asks which one to use, with its best guess (the first track not tagged English) preselected. The log always says which track was used.

- Drag one or more movies (or a folder) onto the window or onto the app's Dock icon. You can also click **Choose Files…**.
- Watch the progress bar and log. When the job finishes, `Movie.srt` sits next to `Movie.mkv`. The log lists each part's English lines, so you can see where Whisper returned nothing.
- Open the movie in VLC and the subtitles appear. If they don't, use **Subtitle → Add Subtitle File…** in VLC.
- If macOS asks for access to Downloads, Desktop or another folder, click **OK**. The app needs it to save the `.srt` next to the movie.

**Settings** (⌘,) has:
- The model: `whisper-large-v3` is the default and best for translation.
- The centre-channel "dialogue focus" option.
- **Clear Saved Progress**, which deletes the remembered parts of unfinished jobs.

Each tab (Subtitles, Cutter, Joiner) has its own log at the bottom of the window, with **Copy Log** and **Clear Log** buttons (clearing only empties the window; the files are kept). The logs are also written to `~/Library/Logs/EnglishSubtitleMaker/` as `Subtitles.log`, `Cutter.log` and `Joiner.log` (**Open Log Folder** button).

## Error codes

| Code | Meaning | What to do |
|---|---|---|
| E101 | ffmpeg not found | Re-download the app (ffmpeg is inside it). |
| E102 | Can't read the video file | Check the file plays in VLC. Allow folder access in System Preferences → Security & Privacy → Files and Folders. |
| E103 | No audio track | The file has no audio ffmpeg can read. |
| E104 | Audio extraction failed | The file may be damaged. See the ffmpeg lines in the log. |
| E105 | Audio splitting failed | See the ffmpeg lines in the log. |
| E201 | No Groq API key | Paste your key at the top of the window. |
| E202 | Key rejected | Create a new key at console.groq.com/keys. |
| E203 | Access refused by Groq | Your account or network can't use the model. |
| E204 | Part too large | Shouldn't happen; please report it with the log. |
| E205 | Request rejected | See Groq's message in the log. |
| E206 | Daily free limit used up | Groq asked for a wait of more than an hour, which means the daily limit (about 8 hours of audio) is reached. Drop the file again later: finished parts are kept. |
| E207 | Groq server error | Retried 4 times automatically; try again later. |
| E208 | Network problem | Retried 4 times automatically; check your connection and drop the file again. |
| E209 | Unexpected reply | Try again; report it with the log if it repeats. |
| E301 | Can't save the .srt | The folder is read-only or macOS blocked access. |
| E302 | No speech found | Check the log to see which audio track was used. |
| E401 | ffprobe not found | Re-download the app (ffprobe is inside it). |
| E402 | Cannot read the video | The file may be damaged or has no video track. |
| E403 | Cutting failed | See the ffmpeg lines in the log; check free disk space. |
| E404 | Joining failed | See the ffmpeg lines in the log; check free disk space. |
| E900 | Cancelled | You stopped the job. Finished parts are kept. |
| E999 | Unexpected error | Please report it with the log. |

## Quality notes

- Whisper large-v3 translates **European languages** (Spanish, French, German, Italian, Portuguese, Dutch, Polish, …) very well.
- **Hindi, Urdu and Bengali** come out decent. **Tamil, Telugu, Malayalam, Kannada and Marathi** are weaker: expect the gist rather than polished dialogue.
- **East Asian languages:**
  - **Japanese and Mandarin Chinese** are among Whisper's stronger languages and usually give good, followable subtitles.
  - **Korean** is also good, but on short parts Whisper sometimes mistakes it for Japanese or Chinese and answers in that language. The app detects this and asks again, then removes any foreign text left over, so expect the odd missing line rather than wrong-language lines.
  - **Cantonese** is weaker: it is often treated as Mandarin, so expect the gist.
- **Southeast Asian languages:**
  - **Indonesian and Malay** (Latin script, close to each other) come out well.
  - **Vietnamese** is decent.
  - **Thai and Tagalog/Filipino** are usable but weaker.
  - **Burmese, Khmer and Lao** are among Whisper's weakest languages: expect frequent gaps and rough meaning.
- These are general observations about Whisper large-v3 rather than measurements from this app; accents, audio quality and dialect make a big difference. The log lists each part's English lines, so you can see where a film has gaps.
- Songs, heavy background music and overlapping speech reduce accuracy.
- Subtitle timing follows Whisper's segments. It's usually within half a second, but occasionally a line appears a little early. Use VLC's subtitle delay (**G** / **H** keys) to nudge it.

## Build from source

Needs Xcode 15+ (or its Command Line Tools) on macOS, plus a static ffmpeg binary:

```
swift test
FFMPEG_BIN=/path/to/ffmpeg scripts/build-app.sh   # → dist/EnglishSubtitlesGenerator-CutJoinVideos-macOS.zip
```

GitHub Actions (`.github/workflows/build.yml`) does this on every push:
1. Runs the unit tests.
2. Downloads a static Intel ffmpeg from [evermeet.cx](https://evermeet.cx/ffmpeg/).
3. Builds the app and checks that both binaries run on macOS 12.
4. Self-tests the packaged app on a synthetic two-track movie.
5. Uploads the zip. Pushing a tag like `v1.0.0` also publishes a release.

Layout:
- `Sources/SubtitleCore`: pure logic (ffmpeg output parsing, chunk planning, Groq types, SRT building), unit-tested.
- `Sources/EnglishSubtitleMaker`: the SwiftUI app, process runner, Groq client and pipeline. `EnglishSubtitleMaker --selftest <file>` runs everything except the upload.

## Third-party software

The app bundles FFmpeg's `ffmpeg` and `ffprobe` (GPL v3); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for sources and license. Speech recognition and translation use [Groq](https://groq.com)'s Whisper API under your own free account.
