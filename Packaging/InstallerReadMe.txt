Lerping@Home installs the screen saver for every user of this Mac.

The Shader Playground is selected by default. Choose Customize to leave it out. The packaged playground carries the built-in shader sources and does not require a source checkout. When you edit and save a built-in shader, it creates a personal override in:

~/Library/Application Support/Lerping/Shaders

The screen saver reads that folder, so saved playground changes are available the next time the screen saver starts.

The standard installer includes licensed 3D captures. A lean installer built from source with MODULES=core omits those captures; it still includes the built-in depth window. Neither edition installs LerpPulse, Minecraft game assets, or the tools for converting photos. Those are separate per-user setup from the source checkout.

Source code, documentation, and notices:
https://github.com/codyhxyz/lerping-at-home
