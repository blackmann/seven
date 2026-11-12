This is the source of `nodes-app/swift-markdown-engine` 0.13.0 (revision
`d1421012aeece640e2c2e47e0e573a93cbe2a420`), used under the bundled
Apache 2.0 license. The app uses a local package because this version has no
host hook for standalone hashtag syntax.

Local changes:

- Style and activate hashtags in `MarkdownASTStyler.swift`.
- Apply the host theme's link color through `NativeTextViewWrapper.swift`.
- Remove upstream test targets from `Package.swift`; upstream tests were not
  copied into this app repository.
- Expose optional host callbacks for standalone slash commands submitted with Return
  and image-embed double-click activation; both ignore fenced code blocks.

Seven copies this vendored engine from W so builds do not depend on a sibling
checkout. Seven supplies system colors and transparent editor surfaces, omits
W's illustration services, and disables macOS AI Writing Tools in the native text
view. The optional code highlighting and LaTeX bridges remain enabled.
