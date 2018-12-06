//
//  CommonUtil.swift
//  cPlayer
//
//  Created by ChaosTong on 2018/12/4.
//  Copyright © 2018 ChaosTong. All rights reserved.
//

import Foundation

class CommonUtil {
  static let shared = CommonUtil()
  
  func bundle(fileName: String) -> String? {
    return Bundle.main.path(forResource: fileName, ofType: "")
  }
}
