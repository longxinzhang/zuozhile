const fs = require('node:fs');
const path = require('node:path');

const home = process.env.DEVECO_HOME;
const roots = [];
if (home) roots.push(path.join(home, 'sdk/default'), path.join(home, 'Contents/sdk/default'));
roots.push('/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/sdk/default',
  '/Applications/DevEco-Studio.app/Contents/sdk/default');
const sdkRoot = roots.find(root => fs.existsSync(path.join(root,
  'openharmony/ets/build-tools/ets-loader/node_modules/typescript')));
if (!sdkRoot) throw Error('Set DEVECO_HOME to the installed DevEco Studio directory');

exports.sdkPath = relative => path.join(sdkRoot, relative);
exports.typescript = require(path.join(sdkRoot, 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
