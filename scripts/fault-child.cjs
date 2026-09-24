const fs = require('fs');
const path = require('path');
const target = process.argv[2];
const staging = target + '.staging';
fs.writeFileSync(staging, Buffer.from('fault-child-durable-orphan'));
const fd = fs.openSync(staging, 'r'); fs.fsyncSync(fd); fs.closeSync(fd);
fs.renameSync(staging, target);
const dfd = fs.openSync(path.dirname(target), 'r'); fs.fsyncSync(dfd); fs.closeSync(dfd);
process.kill(process.pid, 'SIGKILL');
