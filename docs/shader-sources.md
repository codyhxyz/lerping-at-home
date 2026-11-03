# Shader sources

Where Lerping's looks come from, where to find more, and what each source's
licence allows in this repo. Read `PORTING.md` for how to port; this file is
about what you may port.

## The licence rule

This repo is public and AGPL-3.0, so committing code distributes it. Code
from elsewhere may be committed only when it carries an explicit licence that
can be combined with AGPL-3.0:

| OK to port, with attribution | Never commit |
|---|---|
| CC0, public domain, Unlicense | CC BY-NC, CC BY-NC-SA (Shadertoy's default) |
| MIT, BSD, ISC, zlib | CC BY-SA 3.0 |
| Apache-2.0 | Prosperity / Patron (lygia) |
| CC BY 3.0 / 4.0 | No licence stated (all rights reserved) |

"No licence" is the common case on every community gallery, and it means no.
A shader can be clean while a helper inside it is not: mrange's CC0 shaders
often paste snippets marked `License: Unknown`. Check every function, not just
the header. Algorithms, papers and published formulas are not copyrightable:
writing your own implementation from one is always fine.

Put the source URL, author and verbatim licence line in the `.metal` header,
and add a paragraph to `NOTICE.txt`.

## Reference code kept locally

| Library | Where | Licence | Use |
|---|---|---|---|
| [Paper Shaders](https://github.com/paper-design/shaders) | `third_party/paper-shaders` (git submodule, pinned) | Apache-2.0 | Upstream of 28 shipped ports. The GLSL is in template strings in `packages/shaders/src/shaders/*.ts`. Nothing builds from it, so `scripts/install.sh`'s plain clone doesn't need it. |
| [lygia](https://github.com/patriciogonzalezvivo/lygia) | `~/Documents/shader-refs/lygia` (plain clone, outside the repo) | Prosperity 3.0.0 (non-commercial) | Read to learn a technique, then write your own. Never copy from it into this repo. |

After cloning, `git submodule update --init` fetches Paper Shaders. To move
the pin: `git -C third_party/paper-shaders pull` then commit the new pointer,
and say in the commit which upstream changes you are about to port.

## Community galleries

| Site | What's there | Licence reality | How to get the code |
|---|---|---|---|
| [Shadertoy](https://www.shadertoy.com) | The largest collection of single-file fragment shaders | Default CC BY-NC-SA 3.0. Some authors state CC0 or MIT in the code (mrange, Kali's Star Nest, Otavio Good) | Cloudflare blocks curl. The API dump at [GabeRundlett/shadertoy-api-shaders](https://github.com/GabeRundlett/shadertoy-api-shaders) has full code and metadata |
| [glslSandbox](https://glslsandbox.com) | Short demoscene-style single passes, many forks of each | Almost always unlicensed. Trace forks back to the original author | Raw code at the item URLs |
| [Vertex Shader Art](https://www.vertexshaderart.com) | Point and line art driven by `vertexId` | Mostly unstated | Needs re-expressing as a fragment shader or a data provider, since the engine has no vertex pipeline |
| [Twigl](https://twigl.app) / #つぶやきGLSL | Tweet-sized raymarched fractals | Mostly unstated. Look for authors with a licensed GitHub repo | Use the `tweet` CLI for x.com links |
| [Xor](https://www.shadertoy.com/user/Xor) | Compact glow, turbulence, volumetrics | Often CC0 or MIT; check each | Shadertoy (see above) |
| [kishimisu](https://www.shadertoy.com/user/kishimisu) | Neon space-folding loops | Shadertoy default unless stated | Shadertoy |
| [Inigo Quilez](https://www.shadertoy.com/user/iq) | Raymarched landscapes and SDF references | Shadertoy default; port from his articles instead | Shadertoy |

## Techniques (write your own)

- [Inigo Quilez's articles](https://iquilezles.org/articles): SDFs, smooth
  min, domain warping, fBm, cosine palettes, soft shadows, terrain marching.
- [The Book of Shaders](https://thebookofshaders.com): shaping, noise,
  cellular noise, fBm.
- [Ronja's tutorials](https://www.ronja-tutorials.com): 2D SDFs, dithering.
  Code is CC BY 4.0 per
  [the tutorials repo](https://github.com/ronja-tutorials/ShaderTutorials).
- [Karl Sims: reaction-diffusion](https://www.karlsims.com/rd.html)
- [Sage Jenson: Physarum](https://cargocollective.com/sagejenson/physarum)
- [Jos Stam: Real-Time Fluid Dynamics for Games](https://www.dgp.toronto.edu/public_user/stam/reality/Research/pdf/GDC03.pdf)
- [Bridson et al.: Curl-Noise](https://www.cs.ubc.ca/~rbridson/docs/bridson-siggraph2007-curlnoise.pdf)
- [Apple Metal sample code](https://developer.apple.com/metal/sample-code/)

Stateful simulations must follow the bounded-epoch rule in `PORTING.md`.

## Inspiration only

[Tyler Hobbs' essays](https://www.tylerxhobbs.com/words),
[fxhash](https://www.fxhash.xyz), [Art Blocks](https://www.artblocks.io),
[pouet.net](https://www.pouet.net), [Revision](https://revision-party.net),
and the [After Dark](https://en.wikipedia.org/wiki/After_Dark_(software)) era
of screensavers. Look, then make something different.

## Candidates waiting on a licence

Good shaders that were skipped only for licence reasons. Ask the author; a
reply granting CC0 or MIT makes them portable.

| Shader | Where | Problem |
|---|---|---|
| Mandala flowers (mrange) | https://www.shadertoy.com/view/NlcSRB | CC0, but has "License: Unknown" snippets (one by Martijn Steinrucken) |
| Stars and galaxy (mrange) | https://www.shadertoy.com/view/stBcW1 | CC0, but has a snippet by nmz marked "License: Unknown" |
| Seascape, Wet stone (TDM) | Shadertoy / glslSandbox | CC BY-NC-SA |
| Galaxy (Guillitte) | https://glslsandbox.com/e#24643 | CC BY-NC-SA |
| Xor's tweet shaders | x.com/XorDev | No licence on the tweets; he says to assume CC BY-NC-SA 4.0 |
| galaxy zone, microbe -o-, deep galaxy r13, geomertic play -oo- (Yohei Nishitsuji) | https://fragcoord.xyz/s/g5r8ukbb, /s/mbs7vchx, /s/dkonsnwg, /s/glzs27pc | MIT and portable, but 8-18x fractal-multiverse; capping changes the picture |
| "My first FragCoord.xyz shader" (mrange) | https://fragcoord.xyz/s/mkrtrrk7 | CC0, a gorgeous 4D inversion-fractal glow, but ~65 ms at 4K; goes black below ~40 steps |
| Fractal Loop, Wicked Fractal Flight (diatribes) | https://fragcoord.xyz/s/f3m87afg | MIT, but 80+ ms at 4K |

Clean spares nobody has ported yet: Spiral galaxy (mrange, CC0,
https://www.shadertoy.com/view/wsBBWD), DragonEye II (mrange, CC0,
https://glslsandbox.com/e#99585), Xor's CC BY 4.0 pieces on FragCoord
/s/stpng88o, /s/gwznloxf and /s/pwh32upa were checked and turned down for
looking too much like halo. FragCoord has a `cc-by-4.0` tag search that lists
every CC BY piece without crawling.

## Where the November 2026 shaders came from

| Shader | Category | Source |
|---|---|---|
| reaction-diffusion, physarum, ink-fluid, curl-flow | Technique (simulation) | Karl Sims, Jones / Jenson, Stam, Bridson |
| dusk-terrain, agate, cutout-shadows | Technique (fundamentals) | iq articles, Book of Shaders, Ronja (CC BY 4.0) |
| multiverse-cathedral, multiverse-coral, multiverse-lattice | Original, in the Fractal Multiverse idiom | Mandelbox, Apollonian, KIFS + Kaliset |
| sandpile | Metal capability | GPU compute path, see `docs/metal-capabilities.md` |
| star-nest, topologica, sea-and-moon | Shadertoy | MIT, CC0, CC0 |
| halo, fractal-multiverse, simulated-reality, torque, axes, castle-to-castle, fractal-d | Twigl / FragCoord | CC BY 4.0, MIT, MIT, CC BY 4.0, CC BY 4.0, MIT, MIT |
| pulse-rings, string-art | Vertex Shader Art | CC0 (gman) |

glslSandbox turned up the same three Shadertoy shaders, reposted. Its own
entries are almost all unlicensed, and much of its database is now spam. Be
gentle with it: one crawl at ~96 parallel requests coincided with the site
going down. Keep scrapers to a few requests at a time.
