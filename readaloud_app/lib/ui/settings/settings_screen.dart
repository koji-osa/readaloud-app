import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../viewmodel/settings_viewmodel.dart';
import '../../model/setting.dart';
import '../home/widgets/tts_usage_banner.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsViewModelProvider);
    final vm    = ref.read(settingsViewModelProvider.notifier);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ヘッダー
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                '設定',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF0F0F8),
                ),
              ),
            ),

            // Cloud Sync トグル
            _SettingCard(
              child: Row(
                children: [
                  const Icon(Icons.cloud, color: Color(0xFF8888AA)),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Cloud Sync',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF0F0F8),
                      ),
                    ),
                  ),
                  Switch(
                    value: state.cloudSyncEnabled,
                    onChanged: (v) => vm.saveSetting(
                      SettingKeys.cloudSyncEnabled,
                      v.toString(),
                    ),
                    activeColor: const Color(0xFF7C5CBF),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // TTS使用量
            const TtsUsageBanner(),
            const SizedBox(height: 16),

            // 音声設定
            _SectionTitle(title: '音声設定'),
            _SettingCard(
              child: Column(
                children: [
                  _SettingRow(
                    icon: Icons.mic,
                    label: '声の種類',
                    value: state.defaultVoiceId.isEmpty
                        ? '未設定'
                        : state.defaultVoiceId,
                    onTap: () {},
                  ),
                  const _Divider(),
                  _SettingRow(
                    icon: Icons.speed,
                    label: 'デフォルト速度',
                    value: '${state.defaultSpeed}x',
                    onTap: () => _showSpeedDialog(context, vm, state),
                  ),
                  const _Divider(),
                  _SettingRow(
                    icon: Icons.music_note,
                    label: '音程',
                    value: state.defaultPitch,
                    onTap: () {},
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // TTS使用量管理
            _SectionTitle(title: 'TTS使用量管理'),
            _SettingCard(
              child: Column(
                children: [
                  _SettingRow(
                    icon: Icons.bar_chart,
                    label: '月間上限文字数',
                    value: state.ttsMonthlyLimit,
                    onTap: () {},
                  ),
                  const _Divider(),
                  _SettingRow(
                    icon: Icons.notifications,
                    label: 'アラート閾値',
                    value:
                        '${(double.parse(state.ttsAlertThreshold1) * 100).toInt()}% / ${(double.parse(state.ttsAlertThreshold2) * 100).toInt()}%',
                    onTap: () {},
                  ),
                  const _Divider(),
                  _SettingRow(
                    icon: Icons.swap_horiz,
                    label: '上限到達時の動作',
                    value: state.ttsFallbackDevice ? '内蔵TTSに切替' : '停止',
                    onTap: () => vm.saveSetting(
                      SettingKeys.ttsFallbackDevice,
                      (!state.ttsFallbackDevice).toString(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // APIキー設定
            _SectionTitle(title: 'APIキー設定'),
            _SettingCard(
              child: _SettingRow(
                icon: Icons.key,
                label: 'Google Cloud TTS APIキー',
                value: '••••••••••••',
                onTap: () => _showApiKeyDialog(context, vm),
              ),
            ),
            const SizedBox(height: 16),

            // データ管理
            _SectionTitle(title: 'データ管理'),
            _SettingCard(
              child: Column(
                children: [
                  _SettingRow(
                    icon: Icons.upload,
                    label: 'データをエクスポート',
                    value: '',
                    onTap: () {},
                  ),
                  const _Divider(),
                  _SettingRow(
                    icon: Icons.download,
                    label: 'データをインポート',
                    value: '',
                    onTap: () {},
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Future<void> _showSpeedDialog(
    BuildContext context,
    SettingsViewModel vm,
    SettingsState state,
  ) async {
    final speeds = ['0.5', '0.75', '1.0', '1.25', '1.5', '2.0', '2.5', '3.0'];
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: const Text('デフォルト速度',
            style: TextStyle(color: Color(0xFFF0F0F8))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: speeds.map((s) {
            final isSelected = state.defaultSpeed == s;
            return ListTile(
              title: Text('${s}x',
                  style: TextStyle(
                    color: isSelected
                        ? const Color(0xFF9B6FE0)
                        : const Color(0xFFF0F0F8),
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  )),
              onTap: () {
                vm.saveSetting(SettingKeys.defaultSpeed, s);
                Navigator.of(context).pop();
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  Future<void> _showApiKeyDialog(
    BuildContext context,
    SettingsViewModel vm,
  ) async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: const Text('APIキーを設定',
            style: TextStyle(color: Color(0xFFF0F0F8))),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'APIキーを入力...',
            hintStyle: TextStyle(color: Color(0xFF44445A)),
          ),
          style: const TextStyle(color: Color(0xFFF0F0F8)),
          obscureText: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル',
                style: TextStyle(color: Color(0xFF8888AA))),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                // flutter_secure_storageで暗号化保存
                const storage = FlutterSecureStorage();
                await storage.write(
                  key: SettingKeys.ttsApiKey,
                  value: controller.text,
                );
              }
              Navigator.of(context).pop();
            },
            child: const Text('保存',
                style: TextStyle(color: Color(0xFF9B6FE0))),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 11,
          color: Color(0xFF8888AA),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SettingCard extends StatelessWidget {
  final Widget child;
  const _SettingCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF3A3A55)),
      ),
      child: child,
    );
  }
}

class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  const _SettingRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF8888AA), size: 20),
      title: Text(
        label,
        style: const TextStyle(fontSize: 13, color: Color(0xFFF0F0F8)),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value.isNotEmpty)
            Text(
              value,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8888AA)),
            ),
          const Icon(Icons.chevron_right, color: Color(0xFF44445A), size: 18),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      color: Color(0xFF3A3A55),
      indent: 16,
      endIndent: 16,
    );
  }
}
