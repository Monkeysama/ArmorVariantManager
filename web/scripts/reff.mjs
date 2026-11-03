import { copyFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const command = args.shift();
const rootFlag = args.indexOf('--reff-root');
const reffRoot = rootFlag >= 0 ? args[rootFlag + 1] : process.env.REFF_ROOT;
if (!reffRoot || !existsSync(join(reffRoot, 'web/sdk/index.ts'))) {
  throw new Error('请用 REFF_ROOT 或 --reff-root 指定含 web/sdk 的 REFF 源码目录。');
}
const reff = resolve(reffRoot);
const dependencies = join(root, 'node_modules');
if (!existsSync(join(dependencies, 'vite/package.json'))) {
  throw new Error('请先在 web 目录运行 npm ci 安装构建依赖。');
}
const require = createRequire(join(root, 'package.json'));
const sdk = join(reff, 'web/sdk');
const ui = join(reff, 'web/shared/src/index.ts');

if (command === 'typecheck') {
  mkdirSync(join(root, '.cache'), { recursive: true });
  const config = join(root, '.cache/tsconfig.json');
  writeFileSync(config, JSON.stringify({ compilerOptions: {
    target: 'ES2020', module: 'ESNext', moduleResolution: 'Bundler', strict: true,
    skipLibCheck: true, lib: ['ES2020', 'DOM', 'DOM.Iterable'], baseUrl: root,
    paths: { '@reff-sdk/*': [join(sdk, '*')], '@reff/ui': [ui],
      vue: [join(dependencies, 'vue')], 'element-plus': [join(dependencies, 'element-plus')],
      'element-plus/*': [join(dependencies, 'element-plus/*')] },
  }, include: [join(root, 'src/**/*.ts'), join(root, 'src/**/*.vue'), join(root, 'tests/**/*.ts')].map(path => path.replaceAll('\\', '/')) }, null, 2));
  const result = spawnSync(process.execPath, [require.resolve('vue-tsc/bin/vue-tsc.js'), '--noEmit', '-p', config], { stdio: 'inherit' });
  process.exit(result.status ?? 1);
}
if (command !== 'build' && command !== 'dev') throw new Error('用法：node scripts/reff.mjs build|typecheck|dev --reff-root <REFF目录>');
const { build, createServer } = await import(pathToFileURL(require.resolve('vite')).href);
const { default: vue } = await import(pathToFileURL(require.resolve('@vitejs/plugin-vue')).href);
const shared = 'reff://shell/shared/reff-ui.mjs';
const outDir = resolve(root, '../ArmorVariantManager/reframework/reff/plugins/monkeysama.avm/ui/dist');
const config = {
  configFile: false, root, base: './', plugins: [vue()],
  resolve: { alias: { vue: join(dependencies, 'vue'), 'element-plus': join(dependencies, 'element-plus'), '@reff/ui': ui, '@reff-sdk': sdk } },
  server: { host: '127.0.0.1', port: 5178, strictPort: true, fs: { allow: [root, reff] } },
  build: {
    target: 'es2020',
    outDir,
    emptyOutDir: true,
    rollupOptions: { input: join(root, 'index.html'), external: ['vue', '@reff/ui'], output: { paths: { vue: shared, '@reff/ui': shared } } },
  },
};
if (command === 'build') {
  await build(config);
  copyFileSync(join(reff, 'LICENSE'), join(outDir, 'REFF-LICENSE.txt'));
}
else { const server = await createServer(config); await server.listen(); server.printUrls(); }
