# English Subtitle Maker

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
5. **Build the SRT.** It shifts timestamps to film time, removes known Whisper "hallucinations" (such as "Thanks for watching!" over music), merges repeats, splits long lines (max 2 lines × 42 characters), and caps how long a short line stays on screen.

Finished parts are remembered, so if a job is interrupted (daily limit, Wi-Fi drop, quitting the app), drop the same file again and it continues where it stopped.

## Groq free-tier limits

As published by Groq when this was written; they may change:

| Limit | Value | What it means |
|---|---|---|
| Audio per hour | 7,200 s (2 h) | About one feature film per hour. If a long film goes over, the app **waits automatically** and continues. |
| Audio per day | 28,800 s (8 h) | About 3–4 films a day. |
| File size | 25 MB | The app's parts are under 0.3 MB. |
| Requests per minute | 20 | The app sends at most one request every 3.1 s to stay under this; it sets the ~15 min per 2-hour film. |
| Requests per day | 2,000 | About 250 requests per 2-hour film, so the audio limit above is reached first. |

## Install (first time)

1. **Download** `EnglishSubtitleMaker-macOS.zip`:
   - From the repository's **Releases** page, if a release exists, or
   - From **Actions → latest "Build" run → Artifacts**. Artifacts arrive as a zip that contains the zip; unzip both.
2. Unzip, and drag **English Subtitle Maker.app** into **Applications**.
3. The app isn't notarised by Apple (that needs a paid developer account), so macOS blocks it the first time. Either:
   - **Right-click** the app → **Open** → **Open**, or
   - In Terminal, run:
     ```
     xattr -dr com.apple.quarantine "/Applications/English Subtitle Maker.app"
     ```
4. **Get a free Groq API key**:
   1. Go to [console.groq.com/keys](https://console.groq.com/keys) and sign in with Google or email.
   2. Click **Create API Key** and copy the key (it starts with `gsk_`).
   3. Paste it into the box at the top of the app and click **Save**. The app checks the key with Groq straight away.

   The key is stored in `~/Library/Application Support/EnglishSubtitleMaker/groq-api-key`, readable only by your user account.

## Use

- Drag one or more movies (or a folder) onto the window or onto the app's Dock icon. You can also click **Choose Files…**.
- Watch the progress bar and log. When the job finishes, `Movie.srt` sits next to `Movie.mkv`. The log lists each part's English lines, so you can see where Whisper returned nothing.
- Open the movie in VLC and the subtitles appear. If they don't, use **Subtitle → Add Subtitle File…** in VLC.
- If macOS asks for access to Downloads, Desktop or another folder, click **OK**. The app needs it to save the `.srt` next to the movie.

**Settings** (⌘,) has:
- The model: `whisper-large-v3` is the default and best for translation.
- The centre-channel "dialogue focus" option.
- **Clear Saved Progress**, which deletes the remembered parts of unfinished jobs.

The full log is also written to `~/Library/Logs/EnglishSubtitleMaker/EnglishSubtitleMaker.log` (**Open Log Folder** button).

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
| E206 | Free limit used up | Try again later (the log shows Groq's wait time). Finished parts are kept. |
| E207 | Groq server error | Retried 4 times automatically; try again later. |
| E208 | Network problem | Retried 4 times automatically; check your connection and drop the file again. |
| E209 | Unexpected reply | Try again; report it with the log if it repeats. |
| E301 | Can't save the .srt | The folder is read-only or macOS blocked access. |
| E302 | No speech found | Check the log to see which audio track was used. |
| E900 | Cancelled | You stopped the job. Finished parts are kept. |
| E999 | Unexpected error | Please report it with the log. |

## Quality notes

- Whisper large-v3 translates **European languages** (Spanish, French, German, Italian, Portuguese, Dutch, Polish, …) very well.
- **Hindi, Urdu and Bengali** come out decent. **Tamil, Telugu, Malayalam, Kannada and Marathi** are weaker: expect the gist rather than polished dialogue.
- Songs, heavy background music and overlapping speech reduce accuracy.
- Subtitle timing follows Whisper's segments. It's usually within half a second, but occasionally a line appears a little early. Use VLC's subtitle delay (**G** / **H** keys) to nudge it.

## Build from source

Needs Xcode 15+ (or its Command Line Tools) on macOS, plus a static ffmpeg binary:

```
swift test
FFMPEG_BIN=/path/to/ffmpeg scripts/build-app.sh   # → dist/EnglishSubtitleMaker-macOS.zip
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
