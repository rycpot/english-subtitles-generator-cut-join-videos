# Third-party software

## FFmpeg (ffmpeg and ffprobe)

The app bundle includes unmodified static builds of **ffmpeg** and **ffprobe**
(`Contents/Resources/ffmpeg`, `Contents/Resources/ffprobe`), downloaded at build
time from [evermeet.cx](https://evermeet.cx/ffmpeg/). They run as separate
programs; the app starts them to read, cut, join and convert media.

These builds are licensed under the **GNU General Public License version 3**
(they include GPL components such as x264 and x265).

- FFmpeg source code: https://ffmpeg.org/download.html and https://git.ffmpeg.org/ffmpeg.git
- Build details and exact versions of the bundled binaries: https://evermeet.cx/ffmpeg/
  (run `ffmpeg -version` inside the app bundle to see the version and configuration)
- License text: https://www.gnu.org/licenses/gpl-3.0.html

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
