const fs = require('fs');
const path = require('path');
const archiver = require('archiver');

const version = process.env.VERSION;

if (!version) {
  console.error('Error: VERSION environment variable is not set.');
  process.exit(1);
}

console.log(`Building Better Hunter Highlights mod version ${version}`);

// update modinfo.ini with the new version
const modinfoPath = path.resolve(__dirname, 'modinfo.ini');
let modinfoContent = fs.readFileSync(modinfoPath, 'utf-8');

modinfoContent = modinfoContent.replace(
  /^version=.*$/m,
  `version=${version}`
);

fs.writeFileSync(modinfoPath, modinfoContent, 'utf-8');
console.log(`Updated modinfo.ini to version ${version}`);

const distPath = path.resolve(__dirname, 'dist');
if (!fs.existsSync(distPath)) {
  fs.mkdirSync(distPath, { recursive: true });
}

// create zip archive in the dist directory
const output = fs.createWriteStream(path.join(distPath, 'Better-Hunter-Highlights.zip'));
const archive = archiver('zip');

output.on('close', () => {
  console.log(`Created ZIP archive (${archive.pointer()} total bytes)`);
});

archive.on('error', err => {
  console.error('Error creating ZIP archive:', err);
  throw err;
});

archive.pipe(output);

archive.file(modinfoPath, { name: 'modinfo.ini' });
archive.file(path.resolve(__dirname, 'reframework', 'autorun', 'better_hunter_highlights.lua'), {
  name: 'reframework/autorun/better_hunter_highlights.lua'
});

archive.finalize();
