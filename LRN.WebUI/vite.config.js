import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectDirectory = dirname(fileURLToPath(import.meta.url));
const certificatePath = resolve(projectDirectory, '.certs', 'localhost.pem');
const certificateKeyPath = resolve(projectDirectory, '.certs', 'localhost.key');
const hasTrustedDevelopmentCertificate = existsSync(certificatePath) && existsSync(certificateKeyPath);
const httpsOptions = hasTrustedDevelopmentCertificate
  ? { cert: readFileSync(certificatePath), key: readFileSync(certificateKeyPath) }
  : false;

export default defineConfig({
  plugins: [react()],
  base: './',
  server: {
    host: '0.0.0.0',
    port: 5173,
    strictPort: true,
    https: httpsOptions
  },
  preview: {
    https: httpsOptions
  }
});
