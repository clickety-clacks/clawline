//
//  AttachmentError.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import Foundation

enum AttachmentError: LocalizedError {
    case accessDenied
    case invalidData
    case unsupportedType
    case pickerUnavailable
    case cameraUnavailable
    case uploadFailed
    case networkFailure
    case missingBaseURL
    case missingAuth
    case cancelled
    case unknown

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Couldn't access file."
        case .invalidData:
            return "File is unreadable."
        case .unsupportedType:
            return "File type not supported."
        case .pickerUnavailable:
            return "Picker unavailable right now."
        case .cameraUnavailable:
            return "Camera unavailable."
        case .uploadFailed:
            return "Upload failed. Try again."
        case .networkFailure:
            return "Network error. Try again."
        case .missingBaseURL:
            return "No provider configured."
        case .missingAuth:
            return "Not signed in."
        case .cancelled:
            return nil
        case .unknown:
            return "Something went wrong."
        }
    }
}
