const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const path = require('path');
const project = path.resolve(__dirname, '..');
const sourcePath = process.argv[2] || path.join(project, 'docs/reference/legacy-page/index.html');
const outputPath = process.argv[3] || path.join(project, 'test/image_filter_vectors.json');
const source = fs.readFileSync(sourcePath, 'utf8');
const start = source.indexOf('var PAL ='), end = source.indexOf('/* ==================================================================\n   渲染与打包', start);
const context = vm.createContext({}); vm.runInContext(source.slice(start,end), context);
const width=12,height=7,rgb=Array.from({length:width*height*3}, (_, i) => (i*73+Math.floor(i/9)*41+19)%256);
const vectors=[];
for (const mode of ['natural','adaptive','gray','naive']) for(const dither of ['fs','stucki','jarvis','burkes','sierra','atkinson','bayer','none']) for(const space of ['std','linear','srgb']) {
 const options={mode,dither,space}; const cfg={...context.DEF,...options};
 const mapped=context.warmMap(Float64Array.from(rgb),width,height,cfg);
 const codes=context.quantize(mapped,width,height,cfg);
 vectors.push({options,codes:Array.from(codes).join('')});
}
for(const mode of ['natural','adaptive','gray','naive']) for(const castRamp of ['sunset','ember','duotone','sepia']) {
 const options={mode,castRamp,brightness:17,contrast:-23,gamma:1.34,saturation:1.42,warmCast:.76,warmCenter:51,warmSpan:73,warmBoost:.81,coolPull:.37,coolCap:43,coolDesat:.66,warmPull:.32,warmPullCap:28,autoLevels:false,sharpen:.73,dither:'stucki',ditherStrength:.63,space:'linear'};
 const cfg={...context.DEF,...options}; const mapped=context.warmMap(Float64Array.from(rgb),width,height,cfg);
 vectors.push({options,codes:Array.from(context.quantize(mapped,width,height,cfg)).join(''),mapped:Array.from(mapped)});
}
const output={source:'moink-R1.3.4/page/index.html (original warmMap + quantize executed in Node VM)',sourceSha256:crypto.createHash('sha256').update(source).digest('hex'),width,height,rgb,vectors};
fs.writeFileSync(outputPath,JSON.stringify(output));
console.log(`Generated ${vectors.length} original-JavaScript vectors`);
