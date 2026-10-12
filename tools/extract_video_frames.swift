#!/usr/bin/env swift
import AVFoundation
import AppKit
import Foundation

/// Extract evenly spaced frames from a video into PNG files.
/// Usage: extract_video_frames.swift <video> <out_dir> <count> <start_ratio> <end_ratio>

guard CommandLine.arguments.count >= 6 else {
	fputs("Usage: extract_video_frames.swift <video> <out_dir> <count> <start_ratio> <end_ratio>\n", stderr)
	exit(2)
}

let videoPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]
let count = Int(CommandLine.arguments[3]) ?? 8
let startRatio = Double(CommandLine.arguments[4]) ?? 0.25
let endRatio = Double(CommandLine.arguments[5]) ?? 0.78

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let url = URL(fileURLWithPath: videoPath)
let asset = AVURLAsset(url: url)
let duration = CMTimeGetSeconds(asset.duration)
guard duration > 0, count > 0 else {
	fputs("Invalid duration or count\n", stderr)
	exit(1)
}

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: 1024, height: 1024)

for i in 0..<count {
	let t: Double
	if count == 1 {
		t = (startRatio + endRatio) * 0.5 * duration
	} else {
		let u = Double(i) / Double(count - 1)
		t = (startRatio + (endRatio - startRatio) * u) * duration
	}
	let time = CMTime(seconds: t, preferredTimescale: 600)
	do {
		let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
		let rep = NSBitmapImageRep(cgImage: cgImage)
		guard let data = rep.representation(using: .png, properties: [:]) else {
			fputs("PNG encode failed for frame \(i)\n", stderr)
			exit(1)
		}
		let outPath = (outDir as NSString).appendingPathComponent(String(format: "frame_%02d.png", i))
		try data.write(to: URL(fileURLWithPath: outPath))
		print("wrote \(outPath) t=\(String(format: "%.3f", t))")
	} catch {
		fputs("Frame \(i) failed: \(error)\n", stderr)
		exit(1)
	}
}
