//
//  ViewController.swift
//  cPlayer
//
//  Created by ChaosTong on 2018/12/3.
//  Copyright © 2018 ChaosTong. All rights reserved.
//

import UIKit

class ViewController: UIViewController {
  
  var frames = [VideoFrame]()
  //http://devimages.apple.com/iphone/samples/bipbop/gear1/prog_index.m3u8
  override func viewDidLoad() {
    super.viewDidLoad()
    
    let s = CommonUtil.shared.bundle(fileName: "test.flv")
    openFile(s)
  }
  
  func openFile(_ path: String?) {
    let openCode = VideoDecoder.shared.openFile(path)
    if !openCode {
      print("VideoDecoder decode file fail...")
      return
    }
    while !VideoDecoder.shared.isEOF {
      let f1 = VideoDecoder.shared.decodeFrames(0)
      f1.forEach { frames.append($0) }
      if frames.count > 20 { break }
    }
    
    print("")
  }
  
}

