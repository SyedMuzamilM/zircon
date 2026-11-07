# Remove the extra Git file tabs

The custom in-panel file tabs added in `1dcb8d1` were the wrong interpretation of the requested Zed multi-buffer workflow. The user-provided Zed screenshots show one Uncommitted Changes editor with contiguous file headers and excerpts, not a second per-file tab strip inside that editor. This correction removes that strip and its callbacks. The normal workspace editor tab, file headers, Open File controls and enlarged change markers remain.

The two fresh native client-area captures were visually inspected after removal. Portable application checks pass77/81 with four explicit native-only skips. The sequential native rendering chain passes106/106. This removal does not establish editable multi-buffer support: direct source-backed excerpt editing remains unfinished, and Open File is not a substitute for it.
