import 'package:flutter_test/flutter_test.dart';
import 'package:oasx/translation/i18n.dart';
import 'package:oasx/translation/i18n_content.dart';

void main() {
  test('new backend task and named green mark have Chinese labels', () {
    final labels = Messages().all_cn_translate;
    expect(labels[I18n.otherWorldTwilight], '彼世逢魔');
    expect(labels['other_world_twilight_config'], '彼世逢魔配置');
    expect(labels['green_mark_name'], '绿标式神名称');
    expect(labels['green_mark_name_help'], contains('6秒'));
    expect(labels['green_mark_name_help'], contains('未找到则不点击'));
  });

  test('new labels have readable English values', () {
    final labels = Messages().all_us_translate;
    expect(labels[I18n.otherWorldTwilight], 'Otherworld Twilight');
    expect(
      labels['other_world_twilight_config'],
      'Otherworld Twilight Settings',
    );
    expect(labels['green_mark_name'], 'Green Mark Shikigami Name');
    expect(labels['green_mark_name_help'], contains('do not click'));
  });

  test('existing task and numeric green mark labels stay available', () {
    final labels = Messages().all_cn_translate;
    expect(labels[I18n.orochi], '八岐大蛇');
    expect(labels['green_mark'], '设置第 X 个式神为绿标');
    expect(labels['preset_enable'], '启用切换预设队伍');
  });
}
