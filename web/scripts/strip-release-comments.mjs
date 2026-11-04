import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { transform } from 'esbuild';

async function strip(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await strip(path);
    else if (['.js', '.mjs', '.css'].includes(extname(path))) {
      const { code } = await transform(await readFile(path, 'utf8'), {
        loader: extname(path) === '.css' ? 'css' : 'js',
        legalComments: 'none', ignoreAnnotations: true, minifyWhitespace: true,
      });
      await writeFile(path, code);
    }
  }
}

await strip(process.argv[2]);
