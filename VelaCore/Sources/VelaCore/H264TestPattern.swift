#if canImport(VideoToolbox) && canImport(CoreGraphics)
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox

/// Encodes a single synthetic frame locally. This does not transmit or establish a receiver session.
public enum H264TestPattern {
    public struct Encoded {
        public let avcc: Data
        public let sps: Data
        public let pps: Data
    }
    public enum Failure: Error { case buffer, graphics, session(OSStatus), encode(OSStatus), noOutput }
    private final class Output {
        var sample: CMSampleBuffer?
        var status: OSStatus = noErr
    }

    public static func encode(width: Int = 320, height: Int = 180) throws -> Encoded {
        guard width > 0, height > 0, width <= 1920, height <= 1080, width % 2 == 0, height % 2 == 0 else { throw Failure.buffer }
        var pixel: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                           kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { throw Failure.buffer }
        CVPixelBufferLockBaseAddress(pixel, [])
        guard let address = CVPixelBufferGetBaseAddress(pixel),
              let ctx = CGContext(data: address, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(pixel, []); throw Failure.graphics
        }
        let colors: [[CGFloat]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 1]]
        for (index, color) in colors.enumerated() {
            ctx.setFillColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
            ctx.fill(CGRect(x: CGFloat(index * width / 4), y: 0, width: CGFloat((width + 3) / 4), height: CGFloat(height)))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let output = Output()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: { ref, _, code, _, sample in
            guard let ref else { return }
            let result = Unmanaged<Output>.fromOpaque(ref).takeUnretainedValue()
            result.status = code
            result.sample = sample
        }, refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { throw Failure.session(status) }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        var flags = VTEncodeInfoFlags()
        let encodedStatus = VTCompressionSessionEncodeFrame(session, imageBuffer: pixel,
                presentationTimeStamp: CMTime(value: 0, timescale: 30), duration: CMTime(value: 1, timescale: 30),
                frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
        guard encodedStatus == noErr else { throw Failure.encode(encodedStatus) }
        let complete = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard complete == noErr, output.status == noErr, let sample = output.sample,
              let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure.noOutput }
        func parameter(_ index: Int) throws -> Data {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                  parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                  nalUnitHeaderLengthOut: nil) == noErr, let ptr, size > 0 else { throw Failure.noOutput }
            return Data(bytes: ptr, count: size)
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { throw Failure.noOutput }
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        guard copyStatus == noErr else { throw Failure.noOutput }
        return Encoded(avcc: data, sps: try parameter(0), pps: try parameter(1))
    }
}
#endif
