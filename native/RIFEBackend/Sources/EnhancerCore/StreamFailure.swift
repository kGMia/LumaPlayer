import RifeMetal

/// Stable diagnostics ABI; never export localized errors, model paths or URLs.
public enum StreamFailure {
    public static func code(for error: Error) -> Int32 {
        if error is CancellationError { return 102 }
        if error is BackendError { return 200 }
        guard let error = error as? RifeError else { return 299 }
        switch error {
        case .modelLoadFailed: return 201
        case .unsupportedPixelFormat: return 202
        case .dimensionMismatch: return 203
        case .metalUnavailable: return 204
        case .shaderCompilationFailed: return 205
        case .inferenceFailed: return 206
        case .invalidTimesteps: return 207
        }
    }
}
