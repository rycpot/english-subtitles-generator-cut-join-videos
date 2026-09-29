import XCTest
@testable import SubtitleCore

final class FFmpegParsingTests: XCTestCase {
    // Real output of `ffmpeg -hide_banner -i test.mkv` (ffmpeg 6.1).
    let probe = """
    Input #0, matroska,webm, from 'test.mkv':
      Metadata:
        title           : Some Film
        ENCODER         : Lavf60.16.100
      Duration: 01:58:03.52, start: -0.021000, bitrate: 381 kb/s
      Stream #0:0: Video: h264 (Constrained Baseline), yuv420p(progressive), 160x90 [SAR 1:1 DAR 16:9], 5 fps, 5 tbr, 1k tbn
        Metadata:
          ENCODER         : Lavc60.31.102 libx264
      Stream #0:1(hin): Audio: aac (LC), 48000 Hz, 5.1, fltp
        Metadata:
          title           : Hindi
          ENCODER         : Lavc60.31.102 aac
      Stream #0:2[0x1100](eng): Audio: ac3, 48000 Hz, stereo, fltp, 192 kb/s (default)
        Metadata:
          ENCODER         : Lavc60.31.102 aac
      Stream #0:3(eng): Subtitle: subrip
    At least one output file must be specified
    """

    func testParsesDurationAndAudioStreams() {
        let info = FFmpegOutput.parseMediaInfo(probe)
        XCTAssertEqual(info.duration!, 7083.52, accuracy: 0.001)
        XCTAssertEqual(info.audioStreams.count, 2)
        let hin = info.audioStreams[0]
        XCTAssertEqual(hin.audioIndex, 0)
        XCTAssertEqual(hin.language, "hin")
        XCTAssertEqual(hin.title, "Hindi")
        XCTAssertEqual(hin.layout, "5.1")
        XCTAssertTrue(hin.hasCentreChannel)
        XCTAssertFalse(hin.isDefault)
        let eng = info.audioStreams[1]
        XCTAssertEqual(eng.audioIndex, 1)
        XCTAssertEqual(eng.language, "eng")
        XCTAssertNil(eng.title, "container title must not leak into streams")
        XCTAssertEqual(eng.layout, "stereo")
        XCTAssertTrue(eng.isDefault)
        XCTAssertFalse(eng.hasCentreChannel)
    }

    func testPrefersNonEnglishTrack() {
        let info = FFmpegOutput.parseMediaInfo(probe)
        XCTAssertEqual(info.preferredAudioStream()?.language, "hin")

        let onlyEnglish = MediaInfo(duration: 10, audioStreams: [
            AudioStream(audioIndex: 0, language: "eng", title: nil, details: "", isDefault: false, layout: "stereo"),
            AudioStream(audioIndex: 1, language: "eng", title: nil, details: "", isDefault: true, layout: "stereo"),
        ])
        XCTAssertEqual(onlyEnglish.preferredAudioStream()?.audioIndex, 1)
    }

    func testUndeterminedLanguageIsNil() {
        let info = FFmpegOutput.parseMediaInfo("  Stream #0:1(und): Audio: aac (LC), 44100 Hz, stereo, fltp (default)")
        XCTAssertNil(info.audioStreams.first?.language)
        XCTAssertNil(info.duration)
    }

    func testSurroundSideLayout() {
        let info = FFmpegOutput.parseMediaInfo("  Stream #0:1: Audio: eac3, 48000 Hz, 5.1(side), fltp, 640 kb/s")
        XCTAssertEqual(info.audioStreams.first?.layout, "5.1(side)")
        XCTAssertEqual(info.audioStreams.first?.hasCentreChannel, true)
        let six = FFmpegOutput.parseMediaInfo("  Stream #0:1: Audio: pcm_s24le, 48000 Hz, 6 channels, s32")
        XCTAssertEqual(six.audioStreams.first?.hasCentreChannel, false, "unnamed layouts have no FC to select")
    }

    func testParsesLoudness() {
        // Real output of the loudness pass (ffmpeg 6.1).
        let lines = [
            "frame:0    pts:0       pts_time:0",
            "lavfi.astats.Overall.RMS_level=-22.486583",
            "frame:51   pts:81600   pts_time:5.1",
            "lavfi.astats.Overall.RMS_level=-153.932187",
            "frame:52   pts:83200   pts_time:5.2",
            "lavfi.astats.Overall.RMS_level=-inf",
        ]
        XCTAssertEqual(FFmpegOutput.parseLoudness(lines), [
            LoudnessSample(time: 0, db: -22.486583),
            LoudnessSample(time: 5.1, db: -120),
            LoudnessSample(time: 5.2, db: -120),
        ])
    }

    func testProgressLines() {
        XCTAssertEqual(FFmpegOutput.progressSeconds(fromLine: "out_time_us=1500014750")!, 1500.01475, accuracy: 1e-6)
        XCTAssertEqual(FFmpegOutput.progressSeconds(fromLine: "out_time_ms=2000000")!, 2.0, accuracy: 1e-9)
        XCTAssertNil(FFmpegOutput.progressSeconds(fromLine: "out_time_us=N/A"))
        XCTAssertNil(FFmpegOutput.progressSeconds(fromLine: "progress=end"))
    }

    func testSegmentList() {
        let csv = "part_000.mp3,0.000000,596.052000\npart_001.mp3,596.052000,1192.032000\n"
        let parts = FFmpegOutput.parseSegmentList(csv)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1].file, "part_001.mp3")
        XCTAssertEqual(parts[1].start, 596.052, accuracy: 1e-9)
    }
}

final class ChunkPlannerTests: XCTestCase {
    /// 0.1 s samples: loud speech (-20 dB) with a pause (-60 dB) at the given times.
    func envelope(duration: Double, pauses: [ClosedRange<Double>]) -> [LoudnessSample] {
        stride(from: 0.0, to: duration, by: 0.1).map { t in
            LoudnessSample(time: t, db: pauses.contains { $0.contains(t) } ? -60 : -20)
        }
    }

    func testShortAudioIsOnePart() {
        XCTAssertEqual(ChunkPlanner.cutPoints(duration: 25, loudness: envelope(duration: 25, pauses: [])), [])
    }

    func testCutsInThePause() {
        let cuts = ChunkPlanner.cutPoints(duration: 50, loudness: envelope(duration: 50, pauses: [20.0...20.6]))
        XCTAssertEqual(cuts.count, 1)
        XCTAssertGreaterThan(cuts[0], 20.0)
        XCTAssertLessThan(cuts[0], 20.7)
    }

    func testPrefersTheQuietestMoment() {
        var samples = envelope(duration: 50, pauses: [15.0...15.5, 24.0...24.5])
        // The first pause is only a dip, not silence.
        samples = samples.map { $0.time >= 15.0 && $0.time <= 15.5 ? LoudnessSample(time: $0.time, db: -35) : $0 }
        let cuts = ChunkPlanner.cutPoints(duration: 50, loudness: samples)
        XCTAssertGreaterThan(cuts[0], 24.0)
        XCTAssertLessThan(cuts[0], 24.6)
    }

    func testIgnoresASingleQuietSliceInsideAWord() {
        var samples = envelope(duration: 50, pauses: [22.0...22.5])
        samples = samples.map { abs($0.time - 18.0) < 0.01 ? LoudnessSample(time: $0.time, db: -70) : $0 }
        let cuts = ChunkPlanner.cutPoints(duration: 50, loudness: samples)
        XCTAssertGreaterThan(cuts[0], 22.0)
    }

    func testFallsBackToFixedCutsWithoutLoudness() {
        XCTAssertEqual(ChunkPlanner.cutPoints(duration: 70, loudness: []), [28, 56])
    }

    func testEveryPartFitsWhispersWindow() {
        for duration in [29.0, 31.0, 60.0, 61.0, 7200.0] {
            let samples = envelope(duration: duration, pauses: stride(from: 5.0, to: duration, by: 7).map { $0...($0 + 0.8) })
            let cuts = ChunkPlanner.cutPoints(duration: duration, loudness: samples)
            let bounds = [0.0] + cuts + [duration]
            for (a, b) in zip(bounds, bounds.dropFirst()) {
                XCTAssertLessThanOrEqual(b - a, ChunkPlanner.hardMax, "duration \(duration)")
                XCTAssertGreaterThan(b - a, 0)
            }
        }
    }

    func testTinyTailJoinsLastPart() {
        XCTAssertEqual(ChunkPlanner.cutPoints(duration: 29.5, loudness: []), [])
    }

    func testPeakLevelsFindSilentParts() {
        let samples = envelope(duration: 60, pauses: [30.0...60.0])
        let peaks = ChunkPlanner.peakLevels(samples, parts: [(start: 0, end: 30), (start: 30.2, end: 60)])
        XCTAssertEqual(peaks[0]!, -20, accuracy: 1e-9)
        XCTAssertEqual(peaks[1]!, -60, accuracy: 1e-9)
    }
}

final class GroqTypesTests: XCTestCase {
    func testDecodesVerboseJSON() throws {
        let json = """
        {"task":"translate","language":"English","duration":12.5,"text":" Hello. Where are you going?",
         "segments":[{"id":0,"seek":0,"start":0.0,"end":2.5,"text":" Hello.","tokens":[1,2],"temperature":0.0,
                      "avg_logprob":-0.2,"compression_ratio":1.1,"no_speech_prob":0.01},
                     {"id":1,"seek":0,"start":2.5,"end":5.0,"text":" Where are you going?"}],
         "x_groq":{"id":"req_123"}}
        """
        let r = try JSONDecoder().decode(GroqVerboseResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.segments?.count, 2)
        XCTAssertEqual(r.segments?[0].noSpeechProb, 0.01)
        XCTAssertNil(r.segments?[1].avgLogprob)
    }

    func testErrorMessage() {
        let body = #"{"error":{"message":"Invalid API Key","type":"invalid_request_error","code":"invalid_api_key"}}"#
        XCTAssertEqual(GroqErrorEnvelope.message(from: Data(body.utf8)), "Invalid API Key")
        XCTAssertEqual(GroqErrorEnvelope.message(from: Data("Bad Gateway".utf8)), "Bad Gateway")
    }

    func testRetryAfter() {
        XCTAssertEqual(RetryAfter.seconds(header: "17", message: nil), 17)
        let msg = "Rate limit reached for model `whisper-large-v3` on audio seconds per hour (ASH): Limit 7200, Used 7150, Requested 600. Please try again in 7m32.5s. Visit https://console.groq.com/docs/rate-limits for more information."
        XCTAssertEqual(RetryAfter.seconds(header: nil, message: msg)!, 452.5, accuracy: 1e-9)
        XCTAssertEqual(RetryAfter.seconds(header: nil, message: "Please try again in 2h3m4s.")!, 7384, accuracy: 1e-9)
        XCTAssertEqual(RetryAfter.seconds(header: nil, message: "Please try again in 850ms.")!, 0.85, accuracy: 1e-9)
        XCTAssertNil(RetryAfter.seconds(header: nil, message: "no hint here"))
    }

    func testMultipart() {
        var form = MultipartForm(boundary: "XYZ")
        form.addField("model", "whisper-large-v3")
        form.addFile("file", filename: "part_000.mp3", mimeType: "audio/mpeg", data: Data([0x49, 0x44, 0x33]))
        let body = String(decoding: form.finalized(), as: UTF8.self)
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=XYZ")
        XCTAssertTrue(body.hasPrefix("--XYZ\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3\r\n"))
        XCTAssertTrue(body.contains("filename=\"part_000.mp3\"\r\nContent-Type: audio/mpeg\r\n\r\nID3\r\n"))
        XCTAssertTrue(body.hasSuffix("--XYZ--\r\n"))
    }
}

final class SubtitleBuilderTests: XCTestCase {
    func testOffsetsAndFormatting() {
        let chunks = [
            ChunkResult(offset: 0, length: 600, segments: [GroqSegment(start: 1, end: 3, text: " Hello there. ")]),
            ChunkResult(offset: 600, length: 600, segments: [GroqSegment(start: 0.5, end: 2, text: "Where is he?")]),
        ]
        let srt = SubtitleBuilder.srt(from: SubtitleBuilder.buildCues(from: chunks))
        XCTAssertEqual(srt, """
        1
        00:00:01,000 --> 00:00:03,000
        Hello there.

        2
        00:10:00,500 --> 00:10:02,000
        Where is he?


        """)
    }

    func testDropsHallucinations() {
        let segs = [
            GroqSegment(start: 0, end: 2, text: "Thanks for watching!"),
            GroqSegment(start: 2, end: 4, text: "Subtitles by the Amara.org community"),
            GroqSegment(start: 4, end: 6, text: "Hmm", avgLogprob: -1.5, noSpeechProb: 0.9),
            GroqSegment(start: 6, end: 8, text: "Thank you."),
        ]
        let cues = SubtitleBuilder.buildCues(from: [ChunkResult(offset: 0, length: 60, segments: segs)])
        XCTAssertEqual(cues.map(\.text), ["Thank you."])
    }

    func testMergesRepeatedLines() {
        let segs = [
            GroqSegment(start: 0, end: 2, text: "Run!"),
            GroqSegment(start: 2.2, end: 3, text: "run"),
            GroqSegment(start: 10, end: 11, text: "Run!"),
        ]
        let cues = SubtitleBuilder.buildCues(from: [ChunkResult(offset: 0, length: 60, segments: segs)])
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].end, 3, accuracy: 1e-9)
    }

    func testCapsLongDisplayAndFixesOverlap() {
        let segs = [
            GroqSegment(start: 0, end: 20, text: "Yes."),
            GroqSegment(start: 1, end: 3, text: "No."),
        ]
        let cues = SubtitleBuilder.buildCues(from: [ChunkResult(offset: 0, length: 60, segments: segs)])
        XCTAssertLessThanOrEqual(cues[0].end, cues[1].start)
        let single = SubtitleBuilder.buildCues(from: [ChunkResult(offset: 0, length: 60, segments: [segs[0]])])
        XCTAssertEqual(single[0].end, 3, accuracy: 1e-9, "a short line is not left up for 20 s")
    }

    func testSplitsLongTextAndWraps() {
        let long = "I told you a hundred times that we cannot go back to that village after what happened there last winter, do you understand me?"
        let cues = SubtitleBuilder.buildCues(from: [ChunkResult(offset: 0, length: 60, segments: [GroqSegment(start: 0, end: 10, text: long)])])
        XCTAssertGreaterThan(cues.count, 1)
        for cue in cues {
            let lines = SubtitleBuilder.wrap(cue.text).components(separatedBy: "\n")
            XCTAssertLessThanOrEqual(lines.count, 2)
            for line in lines { XCTAssertLessThanOrEqual(line.count, 50) }
        }
        XCTAssertEqual(cues.map(\.text).joined(separator: " "), long)
    }

    func testClampsSegmentsToChunk() {
        let cues = SubtitleBuilder.buildCues(from: [ChunkResult(offset: 100, length: 10, segments: [GroqSegment(start: 8, end: 30, text: "Late.")])])
        XCTAssertEqual(cues[0].start, 108, accuracy: 1e-9)
        XCTAssertEqual(cues[0].end, 110, accuracy: 1e-9)
    }

    func testTimestamp() {
        XCTAssertEqual(SubtitleBuilder.timestamp(3723.4567), "01:02:03,457")
        XCTAssertEqual(SubtitleBuilder.timestamp(-1), "00:00:00,000")
    }
}


final class EnglishCleaningTests: XCTestCase {
    func testForeignRatio() {
        XCTAssertEqual(SubtitleBuilder.foreignRatio("Hello there"), 0)
        XCTAssertEqual(SubtitleBuilder.foreignRatio("真是太可惜了"), 1)
        XCTAssertEqual(SubtitleBuilder.foreignRatio("Café déjà vu"), 0, "accented Latin is English-compatible")
    }

    func testKeepsEnglishPartOfMixedLines() {
        XCTAssertEqual(SubtitleBuilder.englishOnly("女兒 Your daughter"), "Your daughter")
        XCTAssertEqual(SubtitleBuilder.englishOnly("明天見到你。 I'll be there."), "I'll be there.")
        XCTAssertEqual(SubtitleBuilder.englishOnly("《WHY DID I KILL OH EUN-AH?》"), "WHY DID I KILL OH EUN-AH?")
    }

    func testCollapsesSelfRepeatingLines() {
        XCTAssertEqual(SubtitleBuilder.englishOnly("宗吾, tell the professor. 宗吾, tell the professor."), "tell the professor.")
        XCTAssertEqual(SubtitleBuilder.englishOnly("I'm sorry. I'm sorry. I'm the one."), "I'm sorry. I'm sorry. I'm the one.")
    }

    func testDropsForeignOnlyJunkAndFiller() {
        func text(_ t: String) -> String? { SubtitleBuilder.subtitleText(GroqSegment(start: 0, end: 1, text: t)) }
        XCTAssertNil(text("行きましょう。"))
        XCTAssertNil(text("Hello everyone, welcome to my channel."))
        XCTAssertNil(text("《The"))
        XCTAssertNil(text("Welcome"))
        XCTAssertNil(text("I"))
        XCTAssertEqual(text("Let's go."), "Let's go.")
        XCTAssertEqual(text("No."), "No.")
    }
}

final class TimeCodeTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(TimeCode.parse("00:20:00"), 1200)
        XCTAssertEqual(TimeCode.parse("20:00"), 1200)
        XCTAssertEqual(TimeCode.parse("95"), 95)
        XCTAssertEqual(TimeCode.parse("1:02:03.5"), 3723.5)
        XCTAssertEqual(TimeCode.parse(" 00:00:30,250 "), 30.25)
        XCTAssertNil(TimeCode.parse("00:61:00"))
        XCTAssertNil(TimeCode.parse("1e3"))
        XCTAssertNil(TimeCode.parse("1.5:00"))
        XCTAssertNil(TimeCode.parse(""))
        XCTAssertNil(TimeCode.parse("1:2:3:4"))
    }

    func testFormat() {
        XCTAssertEqual(TimeCode.format(1320), "00:22:00")
        XCTAssertEqual(TimeCode.format(3723.5), "01:02:03.500")
        XCTAssertEqual(TimeCode.fileSafe(1200), "00.20.00")
    }

    func testSplitIntoCount() {
        let parts = RangeSplitter.split(start: 1200, end: 1320, mode: .count(4))
        XCTAssertEqual(parts.map(\.start), [1200, 1230, 1260, 1290])
        XCTAssertEqual(parts.last?.end, 1320)
    }

    func testSplitIntoLengthWithShorterLastPart() {
        let parts = RangeSplitter.split(start: 0, end: 100, mode: .length(30))
        XCTAssertEqual(parts.map(\.end), [30, 60, 90, 100])
    }

    func testRangeFields() {
        XCTAssertEqual(try RangeFields(start: "00:20:00", endMode: .duration, end: "00:02:00").resolve(fileDuration: 7200).get(), 1200...1320)
        XCTAssertEqual(try RangeFields(start: "00:20:00", endMode: .endTime, end: "00:22:00").resolve(fileDuration: nil).get(), 1200...1320)
        XCTAssertEqual(RangeFields(start: "00:22:00", endMode: .endTime, end: "00:20:00").resolve(fileDuration: nil), .failure(.notAfterStart))
        XCTAssertEqual(RangeFields(start: "00:59:00", endMode: .duration, end: "00:02:00").resolve(fileDuration: 3600), .failure(.endPastEnd(3600)))
        XCTAssertEqual(try RangeFields(start: "00:59:00", endMode: .endTime, end: "01:00:00.3").resolve(fileDuration: 3600).get(), 3540...3600)
        XCTAssertEqual(RangeFields(start: "abc").resolve(fileDuration: nil), .failure(.badStart))
        XCTAssertEqual(RangeFields().resolve(fileDuration: 60), .failure(.noDuration), "untouched default")
        XCTAssertEqual(RangeFields(endMode: .endTime).resolve(fileDuration: 60), .failure(.noEnd))
    }
}

final class CutPlannerTests: XCTestCase {
    // Keyframes every 2 s at x.023 with a 0.08 s decode delay, like the test film.
    let keys = stride(from: 0.023, to: 120, by: 2).map { Keyframe(pts: $0, dts: $0 - 0.08) }
    let fd = 0.04

    func testParsesKeyframesAndEstimatesMissingDTS() {
        let csv = "0.023000,N/A,K__\n0.183000,N/A,___\n2.023000,1.943000,K__,\n2.063000,1.983000,___\n"
        let k = CutPlanner.parseKeyframes(csv)
        XCTAssertEqual(k.count, 2)
        XCTAssertEqual(k[0].dts, 0.023 - 0.08, accuracy: 1e-9)
        XCTAssertEqual(k[1], Keyframe(pts: 2.023, dts: 1.943))
    }

    func testCopiesBetweenKeyframesAndEncodesEdges() {
        let p = CutPlanner.plan(start: 20.5, end: 32.7, keyframes: keys, frameDuration: fd, firstKeyframe: 0.023, reachesFileEnd: false)
        let k1 = keys[11], k2 = keys[16]   // 22.023 and 32.023
        XCTAssertEqual(p.count, 3)
        XCTAssertEqual(p[0], .encode(start: 20.5, end: k1.pts))
        XCTAssertEqual(p[1], .copy(start: k1.pts, end: k2.pts, fromDTS: k1.dts, toDTS: k2.dts))
        XCTAssertEqual(p[2], .encode(start: k2.pts, end: 32.7))
    }

    func testNoHeadWhenLessThanAFrameBeforeKeyframe() {
        let p = CutPlanner.plan(start: 22.0, end: 30.0, keyframes: keys, frameDuration: fd, firstKeyframe: 0.023, reachesFileEnd: false)
        XCTAssertTrue(p[0].isCopy, "22.0 is less than a frame before the keyframe at 22.023")
        XCTAssertEqual(p[0].start, keys[11].pts)
    }

    func testShortCutInsideOneGroupIsEncoded() {
        XCTAssertEqual(CutPlanner.plan(start: 20.2, end: 21.5, keyframes: keys, frameDuration: fd, firstKeyframe: 0.023, reachesFileEnd: false),
                       [.encode(start: 20.2, end: 21.5)])
    }

    func testFromFileStartNeedsNoStartTrimAndToEndIsCopied() {
        let p = CutPlanner.plan(start: 0, end: 120, keyframes: keys, frameDuration: fd, firstKeyframe: 0.023, reachesFileEnd: true)
        XCTAssertEqual(p, [.copy(start: keys[0].pts, end: 120, fromDTS: nil, toDTS: nil)])
    }

    func testFirstFrameAtOrAfter() {
        let csv = "30.780750,\n30.697333\n30.739042\n30.822458\n"
        XCTAssertEqual(CutPlanner.firstFrame(atOrAfter: 30.7, in: csv), 30.739042)
        XCTAssertEqual(CutPlanner.firstFrame(atOrAfter: 30.739042, in: csv), 30.739042)
        XCTAssertNil(CutPlanner.firstFrame(atOrAfter: 31, in: csv))
    }

    func testOpenGOPKeyframesGetTheirLeadingFrames() {
        // Decode order: I (shown 6.006), then two B frames shown before it, then P.
        let csv = "5.880,5.839,___\n6.006,5.881,K__\n5.964,5.923,___\n5.922,5.964,___\n6.089,6.006,___\n"
            + "8.008,7.883,K__\n8.050,7.924,___\n"
        let k = CutPlanner.parseKeyframes(csv)
        XCTAssertEqual(k, [Keyframe(pts: 6.006, dts: 5.881, lead: 5.922), Keyframe(pts: 8.008, dts: 7.883)])
    }

    func testOpenGOPTailStartsAtTheLastKeyframesLeadingFrames() {
        let open = keys.map { Keyframe(pts: $0.pts, dts: $0.dts, lead: $0.pts - 2 * fd) }
        let p = CutPlanner.plan(start: 20.5, end: 32.7, keyframes: open, frameDuration: fd, firstKeyframe: 0.023, reachesFileEnd: false)
        let k1 = open[11], k2 = open[16]
        XCTAssertEqual(p, [.encode(start: 20.5, end: k1.pts),
                           .copy(start: k1.pts, end: k2.lead, fromDTS: k1.dts, toDTS: k2.dts),
                           .encode(start: k2.lead, end: 32.7)])
    }

    func testChaptersFollowPieces() {
        let ch = [ChapterInfo(start: 0, end: 600, title: "One"), ChapterInfo(start: 600, end: 1200, title: "Two")]
        let out = ChapterPlanner.chapters(for: [(ch, 500, 700), (ch, 0, 100)])
        XCTAssertEqual(out, [ChapterInfo(start: 0, end: 100, title: "One"), ChapterInfo(start: 100, end: 200, title: "Two"),
                             ChapterInfo(start: 200, end: 300, title: "One")])
        let meta = ChapterPlanner.ffmetadata(tags: ["title": "A=B"], chapters: [out[0]])
        XCTAssertTrue(meta.hasPrefix(";FFMETADATA1\ntitle=A\\=B\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=100000\ntitle=One\n"))
    }

    func testProbeDecodingAndSignature() throws {
        let json = """
        {"streams":[{"index":0,"codec_name":"h264","codec_type":"video","width":640,"height":360,"pix_fmt":"yuv420p",
          "r_frame_rate":"24000/1001","avg_frame_rate":"24000/1001","disposition":{"attached_pic":0}},
          {"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2,"tags":{"language":"kor"}},
          {"index":2,"codec_name":"mjpeg","codec_type":"video","disposition":{"attached_pic":1}}],
         "format":{"start_time":"-0.023000","duration":"90.000000","tags":{"title":"Film"}},
         "chapters":[{"start_time":"0.000000","end_time":"60.000000","tags":{"title":"Intro"}}]}
        """
        let p = try ProbeResult.decode(Data(json.utf8))
        XCTAssertEqual(p.video?.index, 0, "cover art is not the main video")
        XCTAssertEqual(p.startTime, -0.023)
        XCTAssertEqual(p.frameDuration, 1001.0 / 24000, accuracy: 1e-9)
        XCTAssertTrue(p.canSmartCut)
        var hevc10 = p
        hevc10.streams[0].codecName = "hevc"
        hevc10.streams[0].pixFmt = "yuv420p10le"
        XCTAssertTrue(hevc10.canSmartCut, "10-bit HEVC is copied between keyframes too")
        var vp9 = p
        vp9.streams[0].codecName = "vp9"
        XCTAssertFalse(vp9.canSmartCut)
        XCTAssertEqual(p.audio.first?.audioLabel, "kor · 2 ch · aac")
        XCTAssertEqual(AudioFiles.fileExtension(forCodec: "aac"), "m4a")
        XCTAssertEqual(AudioFiles.fileExtension(forCodec: "eac3"), "eac3")
        XCTAssertEqual(AudioFiles.fileExtension(forCodec: "dts"), "mka")
        XCTAssertEqual(p.chapterList.first?.title, "Intro")
        var other = p
        other.streams[0].width = 1280
        XCTAssertNotEqual(p.joinSignature, other.joinSignature)
        XCTAssertEqual(p.joinSignature.differences(from: other.joinSignature), ["video size 1280x360 vs 640x360"])
        // Frame rates compare by value, not by how ffprobe wrote the fraction.
        var same = p
        same.streams[0].rFrameRate = "48000/2002"
        XCTAssertEqual(p.joinSignature, same.joinSignature)
        var film24 = p
        film24.streams[0].rFrameRate = "24/1"
        XCTAssertEqual(p.joinSignature.differences(from: film24.joinSignature), ["video frame rate 24.000 vs 23.976"])
    }
}

final class JoinPlannerTests: XCTestCase {
    let hd = JoinSignature(video: ["h264", "1920x1080", "yuv420p", "24000/1001", "1:1"], audio: [], subtitles: [])
    let phone = JoinSignature(video: ["h264", "1280x720", "yuv420p", "30/1", "1:1"], audio: [], subtitles: [])

    func testPicksFormatWithMostRunningTime() {
        let pieces: [(signature: JoinSignature, duration: Double, pixels: Int)] =
            [(phone, 20.0, 1280 * 720), (hd, 5400.0, 1920 * 1080), (phone, 20.0, 1280 * 720)]
        XCTAssertEqual(JoinPlanner.bestTarget(pieces), 1)
        let phoneHeavy: [(signature: JoinSignature, duration: Double, pixels: Int)] =
            [(hd, 60.0, 1920 * 1080), (phone, 50.0, 1280 * 720), (phone, 50.0, 1280 * 720)]
        XCTAssertEqual(JoinPlanner.bestTarget(phoneHeavy), 1, "the first piece of the dominant format")
    }

    func testTieGoesToHigherResolution() {
        XCTAssertEqual(JoinPlanner.bestTarget([(phone, 60, 1280 * 720), (hd, 60, 1920 * 1080)]), 1)
    }
}

final class FrameClockTests: XCTestCase {
    let film = FrameClock(frameDuration: 1001.0 / 24000)   // 23.976 fps

    func testFramesPerSecond() {
        XCTAssertEqual(film.framesPerSecond, 24)
        XCTAssertEqual(FrameClock(frameDuration: 0.04).framesPerSecond, 25)
        XCTAssertEqual(FrameClock(frameDuration: 1001.0 / 30000).framesPerSecond, 30)
    }

    func testRoundTripsThroughFrames() {
        let t = FrameTime(hours: 0, minutes: 2, seconds: 7, frame: 19)
        XCTAssertEqual(film.time(film.seconds(t)), t)
        // Through the text a time field stores (millisecond precision).
        XCTAssertEqual(film.time(TimeCode.parse(TimeCode.format(film.seconds(t)))!), t)
        XCTAssertEqual(film.time(60), FrameTime(minutes: 1))
        XCTAssertEqual(film.time(59.999), FrameTime(minutes: 1), "a hair before a second rounds to it")
    }

    func testOnlyTimesInsideTheVideoAreOffered() {
        let limit = film.time(127.794)   // a 2:07.794 trailer
        XCTAssertEqual(limit, FrameTime(minutes: 2, seconds: 7, frame: 19))
        let early = film.choices(for: FrameTime(minutes: 1, seconds: 30), limit: limit)
        XCTAssertEqual(early.hours, 0...0)
        XCTAssertEqual(early.minutes, 0...2)
        XCTAssertEqual(early.seconds, 0...59)
        XCTAssertEqual(early.frames, 0...23)
        let last = film.choices(for: FrameTime(minutes: 2, seconds: 7), limit: limit)
        XCTAssertEqual(last.seconds, 0...7)
        XCTAssertEqual(last.frames, 0...19)
        XCTAssertEqual(film.clamp(FrameTime(minutes: 2, seconds: 30), to: limit), limit)
        XCTAssertEqual(film.clamp(FrameTime(minutes: 1, seconds: 30), to: limit), FrameTime(minutes: 1, seconds: 30))
    }
}

final class JoinSorterTests: XCTestCase {
    let items = [
        JoinSortItem(name: "Film part 10 of 12.mp4", modified: Date(timeIntervalSince1970: 300), duration: 30),
        JoinSortItem(name: "Film part 2 of 12.mp4", modified: Date(timeIntervalSince1970: 100), duration: nil),
        JoinSortItem(name: "Film part 1 of 12.mp4", modified: Date(timeIntervalSince1970: 200), duration: 29.9),
        JoinSortItem(name: "Film part 2 of 12.mp4", modified: nil, duration: 30.5),
    ]

    func testNaturalNameOrderIsStable() {
        XCTAssertEqual(JoinSorter.order(items, by: .name, ascending: true), [2, 1, 3, 0])
        XCTAssertEqual(JoinSorter.order(items, by: .name, ascending: false), [0, 1, 3, 2])
    }

    func testMissingValuesSortLast() {
        XCTAssertEqual(JoinSorter.order(items, by: .modified, ascending: true), [1, 2, 0, 3])
        XCTAssertEqual(JoinSorter.order(items, by: .modified, ascending: false), [0, 2, 1, 3])
        XCTAssertEqual(JoinSorter.order(items, by: .duration, ascending: true), [2, 0, 3, 1])
        XCTAssertEqual(JoinSorter.order(items, by: .duration, ascending: false), [3, 0, 2, 1])
    }
}
