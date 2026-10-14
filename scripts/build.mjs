import {build} from 'esbuild';
await build({entryPoints:['plugin/src/main.ts'],bundle:true,format:'iife',target:'safari14',outfile:'plugin/main.js',loader:{'.glsl':'text','.hook':'text','.lua':'text'}});
