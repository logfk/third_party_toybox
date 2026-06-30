OHOS Toybox 板端测试 - 使用说明
===================================

目标: 在 Windows (Git Bash) 上通过 hdc 连接主板运行测试

使用步骤:
--------
1. 将本文件夹 (transfer/) 整个拷贝到 Windows 上任意位置

2. 打开 Git Bash，进入该目录:
   cd /d/path/to/transfer

3. 确保 hdc 能连到主板:
   /c/path/to/hdc.exe list targets
   如果为空，先运行:
   /c/path/to/hdc.exe start

4. 运行测试 (全量):
   HDC=/c/path/to/hdc.exe ./run-board.sh

   或只跑指定命令:
   HDC=/c/path/to/hdc.exe ./run-board.sh ls grep ps

环境变量:
--------
HDC          - hdc 可执行文件路径 (默认: hdc)
               例: export HDC=/c/Users/xxx/tools/hdc.exe
TOYBOX_PATH  - 主板上 toybox 所在目录 (默认: /system/bin)
               例: export TOYBOX_PATH=/system/bin
DEBUG=1      - 显示详细执行过程

文件结构:
-------
transfer/
  run-board.sh    - 主运行脚本 (在 Windows Git Bash 中执行)
                    每次运行自动保存日志和生成 HTML 报告到 _reports/
  gen-report.sh   - 独立的日志转 HTML 报告脚本
                    用法: ./run-board.sh 2>&1 | ./gen-report.sh > report.html
  report.html     - 交互式报告查看器 (在浏览器中打开)
                    支持粘贴输出或加载已保存的 .log 文件
  test-oh/        - *.test 测试文件
  scripts/        - runtest.sh 测试框架
  _reports/       - 自动生成的日志和 HTML 报告 (git ignored)
  README.txt      - 本说明
