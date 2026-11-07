import { Config } from '@remotion/cli/config';
import os from 'os';
import { execSync } from 'child_process';

// Drop CPU priority to minimum so Remotion never starves the system
try {
  os.setPriority(os.constants.priority.PRIORITY_LOW);
  execSync(`taskpolicy -b -p ${process.pid} 2>/dev/null`);
} catch (_) {}

// Limit parallel browser renders to 2 (instead of all CPU cores)
Config.setConcurrency(2);
