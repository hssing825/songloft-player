import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:songloft_flutter/shared/widgets/draggable_scrollbar_overlay.dart';

/// 探针：暴露自己的 State 实例，用于判断子树是否被重建。
class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static int instances = 0;
  @override
  void initState() {
    super.initState();
    instances++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 10);
}

void main() {
  testWidgets('多个 scroll position 过渡态不会抛出异常', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1200, 800)),
        child: MaterialApp(
          home: SizedBox(
            width: 320,
            height: 320,
            child: DraggableScrollbarOverlay(
              scrollController: controller,
              totalItemCount: 40,
              child: Stack(
                children: [
                  ListView.builder(
                    controller: controller,
                    itemCount: 40,
                    itemBuilder: (context, index) => Text('first $index'),
                  ),
                  ListView.builder(
                    controller: controller,
                    itemCount: 40,
                    itemBuilder: (context, index) => Text('second $index'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  // songloft-org/songloft#361 回归：歌单页传 `enabled: total > 20`，首次搜索把
  // 结果数从 20 以上压到 20 以下时会翻转该开关，overlay 不得因此重建 child。
  late ScrollController controller;
  setUp(() => controller = ScrollController());
  tearDown(() => controller.dispose());

  Widget host({required int total}) {
    return MediaQuery(
      data: const MediaQueryData(size: Size(400, 800)),
      child: MaterialApp(
        home: Scaffold(
          body: DraggableScrollbarOverlay(
            scrollController: controller,
            totalItemCount: total,
            enabled: total > 20,
            child: const Column(
              children: [_Probe(), TextField(autofocus: true)],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('搜索结果跨过 20 阈值时子树不应被销毁重建', (tester) async {
    _ProbeState.instances = 0;

    // 大歌单：enabled=true，滚动条可用
    await tester.pumpWidget(host(total: 30));
    await tester.pumpAndSettle();
    expect(_ProbeState.instances, 1);

    // 模拟搜索命中少量结果：enabled=false，滚动条隐藏
    await tester.pumpWidget(host(total: 2));
    await tester.pumpAndSettle();

    // 若子树被重建，State 会重新 initState → instances 变 2
    expect(
      _ProbeState.instances,
      1,
      reason: 'enabled 翻转不得销毁重建整个子树（含搜索框 TextField）',
    );
  });

  // songloft-org/songloft#469 回归：播放队列在 DraggableScrollableSheet 里，
  // 竖直拖动会被 sheet/内部 Scrollable 抢进手势竞技场。Listener 走 hit-test 直通，
  // 即使外层挂了 vertical drag 手势识别器，拇指按下 + 拖动仍能推进 ScrollController。
  testWidgets('外层竖直 drag 识别器不应抢走拇指拖动', (tester) async {
    final ctl = ScrollController();
    addTearDown(ctl.dispose);
    var outerDragUpdates = 0;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(400, 800)),
        child: MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              onVerticalDragUpdate: (_) => outerDragUpdates++,
              child: SizedBox(
                width: 400,
                height: 600,
                child: DraggableScrollbarOverlay(
                  scrollController: ctl,
                  totalItemCount: 200,
                  estimatedItemHeight: 50,
                  enabled: true,
                  child: ListView.builder(
                    controller: ctl,
                    itemCount: 200,
                    itemExtent: 50,
                    itemBuilder: (_, i) => Text('row $i'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 触发一次滚动，让滚动条从"未显示"进入 _isVisible 状态，拇指出现。
    ctl.jumpTo(10);
    await tester.pump();
    // 从右侧 hit 区靠上的位置（拇指现在的位置附近）开始向下拖。
    final start = tester.getTopRight(find.byType(DraggableScrollbarOverlay));
    final origin = Offset(start.dx - 16, start.dy + 20);
    await tester.dragFrom(origin, const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(
      ctl.offset,
      greaterThan(1000),
      reason: '拖动拇指应推动 scroll offset，未被外层手势竞技场抢走',
    );
    expect(
      outerDragUpdates,
      0,
      reason: '外层 vertical drag 不应收到事件（Listener 不参与手势竞技场）',
    );
  });

  testWidgets('阈值翻转时 TextField 的输入连接不应被重建', (tester) async {
    final log = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        log.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        null,
      ),
    );

    await tester.pumpWidget(host(total: 30));
    await tester.pumpAndSettle();
    log.clear();

    await tester.pumpWidget(host(total: 2));
    await tester.pumpAndSettle();

    // TextInput.clearClient / setClient 出现说明连接被断开重连，
    // Windows 平台上这会在 IME 组合期间把拼音重复提交。
    expect(
      log,
      isNot(contains('TextInput.clearClient')),
      reason: '输入连接被断开：$log',
    );
  });
}
