import {continueRender, delayRender, staticFile} from 'remotion';

const faces = [
  new FontFace('Geist', `url(${staticFile('fonts/Geist-VariableFont_wght.ttf')})`, {weight: '100 900'}),
  new FontFace('Geist Mono', `url(${staticFile('fonts/geist-mono-latin-500.woff2')})`, {weight: '500'}),
  // Apple's system faces, from /System/Library/Fonts. SFNS is variable with an
  // optical-size axis, so it renders as SF Pro Display at display sizes.
  new FontFace('SF Pro', `url(${staticFile('fonts/SFNS.ttf')})`, {weight: '1 1000'}),
  new FontFace('SF Mono', `url(${staticFile('fonts/SFNSMono.ttf')})`, {weight: '1 1000'}),
];
const handle = delayRender('Loading Geist');
Promise.all(faces.map((f) => f.load()))
  .then((loaded) => {
    loaded.forEach((f) => document.fonts.add(f));
    continueRender(handle);
  })
  .catch((err) => {
    console.error(err);
    continueRender(handle);
  });
