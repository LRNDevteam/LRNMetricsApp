import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import basicSsl from '@vitejs/plugin-basic-ssl';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectDirectory = dirname(fileURLToPath(import.meta.url));
const certificatePath = resolve(projectDirectory, '.certs', 'localhost.pem');
const certificateKeyPath = resolve(projectDirectory, '.certs', 'localhost.key');
const hasTrustedDevelopmentCertificate = existsSync(certificatePath) && existsSync(certificateKeyPath);
const httpsOptions = hasTrustedDevelopmentCertificate
  ? { cert: readFileSync(certificatePath), key: readFileSync(certificateKeyPath) }
  : true;

export default defineConfig({
  plugins: [react(), ...(hasTrustedDevelopmentCertificate ? [] : [basicSsl()])],
  base: './',
  server: {
    host: '0.0.0.0',
    port: 5173,
    strictPort: true,
    https: httpsOptions,
    // No trusted dev certificate is present (LRN.WebUI/.certs/localhost.pem+key), so the server
    // falls back to @vitejs/plugin-basic-ssl's auto-generated, browser-untrusted certificate. The
    // page itself loads once you click through the browser's warning, but the HMR client's
    // separate wss:// upgrade over that untrusted cert gets rejected and retries forever, flooding
    // the console and burning CPU. Disable HMR until a trusted cert is generated (e.g. via mkcert)
    // and dropped in .certs/, then restore hmr: { protocol: 'wss', clientPort: 5173 }.
    hmr: false
  },
  preview: {
    https: httpsOptions
  }
});
