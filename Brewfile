# Developer tooling for Verdant. Install with: brew bundle
# (Xcode 26 + the iOS 26 SDK must be installed separately from the App Store / Apple Developer.)
#
# CI pins swiftformat and swiftlint to exact releases (see .github/workflows/ci.yml); Homebrew
# cannot pin, so it installs latest. Those agree today — swiftformat 0.62.1, swiftlint 0.65.0 —
# but if a newer release lands locally and flags files CI accepts, match CI rather than reformat.
# SwiftFormat must be >= 0.62: .swiftformat names rules that older versions reject.
brew "xcodegen"    # generates Verdant.xcodeproj from project.yml
brew "swiftlint"   # linting
brew "swiftformat" # formatting
brew "xcbeautify"  # readable xcodebuild output
