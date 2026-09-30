import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Same local HTTPS convention as LRN.WebUI: drop a trusted localhost cert in .certs/ to serve over
// https (needed for the MVC login cookie to flow to AuthToken).
const projectDirectory = dirname(fileURLToPath(import.meta.url));
const certificatePath = resolve(projectDirectory, '.certs', 'localhost.pem');
const certificateKeyPath = resolve(projectDirectory, '.certs', 'localhost.key');
const httpsOptions = existsSync(certificatePath) && existsSync(certificateKeyPath)
  ? { cert: readFileSync(certificatePath), key: readFileSync(certificateKeyPath) }
  : false;

export default defineConfig({
  plugins: [react()],
  // Relative base + HashRouter: the build runs from any IIS sub-folder without rewrite rules.
  base: './',
  server: {
    host: '0.0.0.0',
    port: 5174,
    strictPort: true,
    https: httpsOptions
  },
  preview: {
    https: httpsOptions
  }
});
