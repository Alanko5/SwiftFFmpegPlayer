//
//  VideoDecoder.swift
//  cPlayer
//
//  Created by ChaosTong on 2018/12/4.
//  Copyright © 2018 ChaosTong. All rights reserved.
//

import Foundation
import CoreGraphics
import CoreVideo
import Accelerate

enum FrameType {
  case AudioFrame
  case VideoFrame
}

public struct BuriedPoint {
  var beginOpen = 0.0                 // 开始试图去打开一个直播流的绝对时间
  var successOpen = 0.0               // 成功打开流花费时间
  var firstScreenTimeMills: Float = 0 // 首屏时间
  var failOpen = 0.0                  // 流打开失败花费时间
  var failOpenType: Int32 = 0         // 流打开失败类型
  var retryTimes: Int = 0             // 打开流重试次数
  var duration = 0.0                  // 拉流时长
  var bufferStatusRecords: [Any] = [] // 拉流状态
  
}

public struct Frame {
  var type: FrameType = .AudioFrame
  var position: Double = 0
  var duration: Double = 0
}

public struct AudioFrame {
  var frame: Frame
  var samples: Data
  
  init(_ frame: Frame, _ samples: Data) {
    self.frame = frame
    self.samples = samples
  }
}

public struct VideoFrame {
  var frame: Frame = Frame.init()
  var width: Int32 = 0
  var height: Int32 = 0
  var linesize: Int32 = 0
  var luma: Data = Data()
  var chromaB: Data = Data()
  var chromaR: Data = Data()
  var imageBuffer: Any? = nil
}

typealias SwrContext = OpaquePointer
typealias SwsContext = OpaquePointer

class VideoDecoder {
  
  static let shared = VideoDecoder()
  
  var formatCtx: UnsafeMutablePointer<AVFormatContext>? = nil
  var isOpenInputSuccess = false
  var buriedPoint = BuriedPoint.init()
  var totalVideoFramecount = 0
  let decodeVideoFrameWateTimeMills: Int64 = 0
//  var videoStreams: [Int] = []
//  var audioStreams: [Int] = []
  var videoStream: UnsafeMutablePointer<AVStream>? = nil
  var audioStream: UnsafeMutablePointer<AVFrame>? = nil
  var videoStreamIndex = -1
  var audioStreamIndex = -1
  var videoCodecCtx: UnsafeMutablePointer<AVCodecContext>? = nil
  var audioCodecCtx: UnsafeMutablePointer<AVCodecContext>? = nil
  var videoTimeBase: CDouble = 0
  var audioTimeBase: CDouble = 0
  
  var videoFrame: UnsafeMutablePointer<AVFrame>? = nil
  var audioFrame: UnsafeMutablePointer<AVFrame>? = nil
  
  var fps: CDouble = 0
  let decodePosition: CGFloat = 0
  var isSubscribe = false
  var isEOF = false
  var swrContext: SwrContext? = nil
  let swrBufferSize = 0
  let picture: AVPicture = AVPicture.init()
  let pictureValid = false
  let swsContext: UnsafeMutablePointer<SwrContext>? = nil
  var subscribeTimeOutTimeInSecs = 20
  var readLastestFrameTime = 0.0
  var interrupted = false
  var connectionRetry = 0
  
  open func openFile(_ path: String?) -> Bool {
    var ret = true
    guard let path = path else { return false }
    connectionRetry = 0
    totalVideoFramecount = 0
    subscribeTimeOutTimeInSecs = 20
    interrupted = false
    isSubscribe = false
    buriedPoint = BuriedPoint.init()
    buriedPoint.bufferStatusRecords = []
    readLastestFrameTime = Date().timeIntervalSince1970
    avformat_network_init()
    av_register_all()
    buriedPoint.beginOpen = Date().timeIntervalSince1970 * 1000
    let openInputErrCode = openInput(path)
    if (openInputErrCode > 0) {
      buriedPoint.successOpen = (Date().timeIntervalSince1970 * 1000 - buriedPoint.beginOpen) / 1000.0
      buriedPoint.failOpen = 0.0
      buriedPoint.failOpenType = 1
      av_dump_format(formatCtx, 0, path.cString(using: .utf8), 0)
      let openVideoStatus = openVideoStream()
      let openAudioStatus = openAudioStream()
      if !openAudioStatus || !openVideoStatus {
        closeFile()
        ret = false
      }
    } else {
      buriedPoint.failOpen = (Date().timeIntervalSince1970 * 1000 - buriedPoint.beginOpen) / 1000.0
      buriedPoint.successOpen = 0.0
      buriedPoint.failOpenType = openInputErrCode
      ret = false
    }
    if ret {
      //在网络的播放器中有可能会拉到长宽都为0 并且pix_fmt是None的流 这个时候我们需要重连
//      var videoWidth = frameWidth()
//      var videoHeight = frameHeight()
//      var retryTimes = 5
//      while (videoWidth <= 0 || videoHeight <= 0) && retryTimes > 0 {
//        print("because of videoWidth and videoHeight is Zero We will Retry...")
//        usleep(useconds_t(500 * 1000))
//        connectionRetry = 0
//        ret = openFile(path)
//        if !ret {
//          break
//        }
//        retryTimes -= 1
//        videoWidth = frameWidth()
//        videoHeight = frameHeight()
//      }
    }
    isOpenInputSuccess = ret
    return ret
  }
  
  fileprivate func openVideoStream() -> Bool {
    videoStreamIndex = -1
    guard let formatCtx = formatCtx else { return false }
    let videoStreams = collectStreamIndexs(formatCtx, codecType: AVMEDIA_TYPE_VIDEO)

    for n in videoStreams {
      guard let stream = formatCtx.pointee.streams[n] else { return false }
      let codecCpa = stream.pointee.codecpar
      //(codecCtx?.pointee.codec_id)!
      guard let codec = avcodec_find_decoder((codecCpa?.pointee.codec_id)!) else {
        print("Finde Video Decoder Failed codec_id")
        return false
      }
//      guard let codecCtx = avcodec_alloc_context3(codec) else { return false }
      guard let codecCtx = stream.pointee.codec else { return false }
      if avcodec_open2(codecCtx, codec, nil) < 0 {
        print("open Video Codec Failed")
        return false
      }
      
      videoFrame = av_frame_alloc()
      guard let _ = videoFrame else {
        print("Alloc Video Frame Failed...")
        avcodec_close(codecCtx)
        return false
      }
      
      videoStreamIndex = n
      videoCodecCtx = codecCtx
      videoStream = stream
      
      if let st = formatCtx.pointee.streams[videoStreamIndex] {
        (self.fps, self.videoTimeBase) = avStreamFPSTimeBase(st, codecCtx, 0.04)
      }
      // 我们先只要一路流
      break
    }
    return true
  }
  
  fileprivate func openAudioStream() -> Bool {
    audioStreamIndex = -1
    guard let formatCtx = formatCtx else { return false }
    let audioStreams = collectStreamIndexs(formatCtx, codecType: AVMEDIA_TYPE_AUDIO)
    
    for n in audioStreams {
      guard let stream = formatCtx.pointee.streams[n] else { return false }
      guard let codecCpa = stream.pointee.codecpar else { return false }
      
      guard let codec = avcodec_find_decoder(codecCpa.pointee.codec_id) else {
        print("Finde Audio Decoder Failed codec_id")
        return false
      }
      
      guard let codecCtx = avcodec_alloc_context3(codec) else { return false }
      if avcodec_open2(codecCtx, codec, nil) < 0 {
        print("open Audio Codec Failed")
        return false
      }
      
      var swrContext: SwrContext? = nil
      if !audioCodecIsSupported(codecCtx) {
        print("because of audio Codec Is Not Supported so we will init swresampler...")
        swrContext = swr_alloc_set_opts(nil, av_get_default_channel_layout(codecCpa.pointee.channels), AV_SAMPLE_FMT_S16, codecCpa.pointee.sample_rate, av_get_default_channel_layout(codecCpa.pointee.channels), AVSampleFormat(rawValue: codecCpa.pointee.format), codecCpa.pointee.sample_rate, 0, nil)
        
        if swrContext == nil || swr_init(swrContext!) != 0 {
          if swrContext != nil {
            swr_free(&swrContext)
          }
          avcodec_close(codecCtx)
          print("init resampler failed...")
          return false
        }
        audioFrame = av_frame_alloc()
        guard let _ = audioFrame else {
          print("Alloc Audio Frame Failed...")
          if swrContext != nil {
            swr_free(&swrContext)
          }
          avcodec_close(codecCtx)
          return false
        }
        
        audioStreamIndex = n
        audioCodecCtx = codecCtx
        self.swrContext = swrContext
        
        if let st = formatCtx.pointee.streams[audioStreamIndex] {
          (_ , self.audioTimeBase) = avStreamFPSTimeBase(st, codecCtx, 0.025)
        }
        
        break
      }
    }
    return true
  }
  
  fileprivate func audioCodecIsSupported(_ audioCodeCtx:UnsafeMutablePointer<AVCodecContext>) -> Bool{
    if (audioCodeCtx.pointee.sample_fmt == AV_SAMPLE_FMT_S16) {
      print("\(audioCodeCtx.pointee.sample_rate),\(audioCodeCtx.pointee.channels)")
      return true
    }
    return false;
  }
  
  fileprivate func avStreamFPSTimeBase(_ st: UnsafeMutablePointer<AVStream>, _ codecCtx: UnsafeMutablePointer<AVCodecContext>, _ defaultTimeBase: CDouble) -> (pFPS: CDouble, pTimeBase: CDouble) {
    
    var fps: CDouble = 0
    var timebase: CDouble = 0
    
    if (st.pointee.time_base.den >= 1) && (st.pointee.time_base.num >= 1) {
      timebase = av_q2d(st.pointee.time_base)
    } else if (codecCtx.pointee.time_base.den >= 1) && (codecCtx.pointee.time_base.num >= 1) {
      timebase = av_q2d(codecCtx.pointee.time_base)
    } else {
      timebase = defaultTimeBase;
    }
    
    if (codecCtx.pointee.ticks_per_frame != 1) {
      print("WARNING: st.codec.ticks_per_frame=\(codecCtx.pointee.ticks_per_frame)")
    }
    
    if (st.pointee.avg_frame_rate.den >= 1) && (st.pointee.avg_frame_rate.num >= 1) {
      fps = av_q2d(st.pointee.avg_frame_rate)
    } else if (st.pointee.r_frame_rate.den >= 1) && (st.pointee.r_frame_rate.num >= 1) {
      fps = av_q2d(st.pointee.r_frame_rate)
    } else {
      fps = 1.0 / timebase
    }
    print(fps, timebase)
    return (fps, timebase)
  }
  
  fileprivate func collectStreamIndexs(_ formatContext: UnsafePointer<AVFormatContext>, codecType: AVMediaType) -> Array<Int>{
    
    var streamIndexs = Array<Int>()
    
    for i in 0..<Int(formatContext.pointee.nb_streams) {
      if codecType == formatContext.pointee.streams[i]?.pointee.codecpar.pointee.codec_type {
        streamIndexs.append(i)
      }
    }
    
    return streamIndexs
  }
  
  fileprivate func openInput(_ path: String) -> Int32 {
    formatCtx = avformat_alloc_context()
    var openInputErrCode = openFormatInput(&formatCtx, path)
    if openInputErrCode != 0 {
      print("open failed")
      if let formatCtx = formatCtx {
        avformat_free_context(formatCtx)
      }
      return openInputErrCode
    }
    // dont forget this, important
    openInputErrCode = avformat_find_stream_info(formatCtx, nil)
    if openInputErrCode < 0 {
      print("open failed")
      if let formatCtx = formatCtx {
        avformat_free_context(formatCtx)
      }
      return openInputErrCode
    }
    return 1
  }
  
  open func decodeFrames(_ minDuaration: Double) -> [VideoFrame] {
    var finished = false
    var packet = AVPacket.init()
    var result = [VideoFrame]()
    var decodedDuration = 0.0
    while !finished {
      if av_read_frame(formatCtx, &packet) < 0 {
        isEOF = true
        break
      }
      var pktSize = packet.size
      let pktStreamIndex = packet.stream_index
      if pktStreamIndex == videoStreamIndex {
        let frame = decodeVideo(&packet, &pktSize)
        totalVideoFramecount += 1
        result.append(frame)
        decodedDuration += frame.frame.duration
        if decodedDuration > minDuaration {
          finished = true
        }
      } else if pktStreamIndex == audioStreamIndex {
        
      } else {
        print("We Can Not Process Stream Except Audio And Video Stream...")
      }
      av_packet_unref(&packet)
    }
    readLastestFrameTime = Date().timeIntervalSince1970
    return result
  }
  
  fileprivate func decodeVideo(_ packet: inout AVPacket, _ packetSize: inout Int32) -> VideoFrame {
    var frame = VideoFrame()
    while packetSize > 0 {
      var gotframe: Int32 = 0
      let ret = avcodec_decode_video2(videoCodecCtx, videoFrame, &gotframe, &packet)
//      let ret = avcodec_send_packet(videoCodecCtx, &packet)
//      gotframe = avcodec_receive_frame(videoCodecCtx, videoFrame)
      if ret < 0 || gotframe < 0 {
        print("decode video error, skip packet ")
        break
      }
      if gotframe > 0 {
        if let decodedFrame = handleVideoFrame() {
          frame = decodedFrame
        }
      }
      if 0 == ret { break }
      packetSize -= ret
    }
    return frame
  }
  
  fileprivate func handleVideoFrame() -> VideoFrame? {
    var frame = VideoFrame()
    if videoCodecCtx?.pointee.pix_fmt == AV_PIX_FMT_YUV420P || videoCodecCtx?.pointee.pix_fmt == AV_PIX_FMT_YUVJ420P {
      if videoFrame?.pointee.data.0 == nil { return nil }
      frame.luma = copyFrameData(videoFrame!.pointee.data.0!, lineSize: videoFrame!.pointee.linesize.0, width: videoCodecCtx!.pointee.width, height: videoCodecCtx!.pointee.height) as Data
      frame.chromaB = copyFrameData(videoFrame!.pointee.data.1!, lineSize: videoFrame!.pointee.linesize.1, width: videoCodecCtx!.pointee.width / 2, height: videoCodecCtx!.pointee.height / 2) as Data
      frame.chromaR = copyFrameData(videoFrame!.pointee.data.2!, lineSize: videoFrame!.pointee.linesize.2, width: videoCodecCtx!.pointee.width / 2, height: videoCodecCtx!.pointee.height / 2) as Data
    } else {
      print("")
    }
    frame.width = videoCodecCtx?.pointee.width ?? 0
    frame.height = videoCodecCtx?.pointee.height ?? 0
    frame.linesize = videoFrame?.pointee.linesize.0 ?? 0
    frame.frame.type = .VideoFrame
    frame.frame.position = Double(av_frame_get_best_effort_timestamp(videoFrame!)) * videoTimeBase
    
    let frameDuration = av_frame_get_pkt_duration(videoFrame)
    if frameDuration > 0 {
      frame.frame.duration = Double(frameDuration) * videoTimeBase
      frame.frame.duration += Double((videoFrame?.pointee.repeat_pict)!) * videoTimeBase * 0.5
    } else {
      frame.frame.duration = 1.0 / fps
    }
    return frame
  }
  
  fileprivate func copyFrameData(_ source: UnsafeMutablePointer<UInt8>, lineSize: Int32, width: Int32, height: Int32) -> NSMutableData{
    let width = Int(min(width, lineSize))
    let height = Int(height)
    var src = source
    
    let data: NSMutableData! = NSMutableData(length: width * height)
//    let s = Data.init(count: width*height)
    let dataPointer = data?.mutableBytes
    
    if var dst = dataPointer {
      for _ in 0..<height {
        
        memcpy(dst, src, width)
        dst += width
        src = src.advanced(by: Int(lineSize))
      }
    }
    
    return data
  }
  
  fileprivate func openFormatInput(_ formatContext: inout UnsafeMutablePointer<AVFormatContext>?, _ path: String) -> Int32 {
    let videoSourceURI = path.cString(using: .utf8)
    return avformat_open_input(&formatContext, videoSourceURI, nil, nil)
  }
  
  fileprivate func closeFile() {
    print("close file")
    if buriedPoint.failOpenType == 1 {
      buriedPoint.duration = (Date().timeIntervalSince1970 * 1000 - buriedPoint.beginOpen) / 1000.0
    }
  }
  
  fileprivate func frameWidth() -> Int32 {
    if let videoCodecCtx = videoCodecCtx {
      return videoCodecCtx.pointee.width
    }
    return 0
  }
  
  fileprivate func frameHeight() -> Int32 {
    if let videoCodecCtx = videoCodecCtx {
      return videoCodecCtx.pointee.height
    }
    return 0
  }
}
