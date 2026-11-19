#!/usr/bin/env node

'use strict';

const fs   = require('fs');
const path = require('path');

const [,, command, ...flags] = process.argv;

if (command === 'install' && flags.includes('--skills')) {
  installSkills();
} else {
  console.log('Usage: adops install --skills');
  process.exit(1);
}

function installSkills() {
  const src  = path.join(__dirname, '..', '.github', 'skills', 'ado-powershell');
  const dest = path.join(process.cwd(), '.github', 'skills', 'ado-powershell');

  copyDir(src, dest);

  console.log(`ado-powershell skill installed -> ${dest}`);
  console.log('GitHub Copilot and Claude Code will now use it in this project.');
}

function copyDir(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const srcPath  = path.join(src,  entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}
