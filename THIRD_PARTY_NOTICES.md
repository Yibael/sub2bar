# Third-party notices

## LobeHub Icons

Source: https://github.com/lobehub/lobe-icons

Pinned commit: `a94750e3f5f8fc33757b839d85030e742284e43a`

Files: `packages/static-svg/icons/{openai,claude,gemini,antigravity}.svg`

Original SVGs are preserved in `Resources/ProviderIcons/`. The generated
`Sources/Sub2Bar/LobeBrandPaths.swift` converts their paths to native SwiftUI
vectors, with elliptical arcs approximated by cubic curves. The original
24×24 viewport and even-odd fill are preserved; color follows the app theme.

`scripts/generate-provider-paths.py` uses ReportLab 4.4.9 only when updating
these generated paths. Normal app builds need neither Python packages nor
network access. Use its `--check` option to verify reproducibility.

The icons identify the account platform, not an affiliation or endorsement.
Brand names and marks belong to their respective owners. This third-party
license does not choose a license for Sub2Bar itself.

### MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
