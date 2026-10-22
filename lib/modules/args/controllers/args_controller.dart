part of args;

class ArgsController extends GetxController {
  ArgsController({
    Future<Map<String, dynamic>> Function(String config, String task)?
        loadArguments,
  }) : _loadArguments =
      loadArguments ??
      ((config, task) => ApiClient().getScriptTask(config, task));

  final Future<Map<String, dynamic>> Function(String config, String task)
      _loadArguments;
  final groups = Rx<List<GroupsModel>>([]);
  final groupsName = Rx<List<String>>([]);
  final groupsData = Rx<Map<String, GroupsModel>>({});
  final dirtyFieldKeys = <String>{}.obs;
  final fieldErrors = <String, String>{}.obs;
  final isDraftMode = false.obs;
  final isSavingDraft = false.obs;
  final scopeScriptCount = 1.obs;
  static const String schedulerGroup = 'scheduler';
  static const String nextRunArg = 'next_run';
  static const String enableArg = 'enable';
  static final RegExp _dateTimePattern =
      RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$');
  static final RegExp _timePattern = RegExp(r'^\d{2}:\d{2}:\d{2}$');
  static final RegExp _timeDeltaPattern = RegExp(r'^\d{2,} \d{2}:\d{2}:\d{2}$');

  final Map<String, dynamic> _originalValues = {};
  String _loadedConfig = '';
  String _loadedTask = '';
  List<String> _scopeScripts = const [];
  SaveArgumentCallback? _saveArgumentOverride;
  SaveArgumentCallback Function(List<String> scopeScripts)?
      _saveArgumentFactory;
  int _loadGeneration = 0;

  static bool isImmediateSchedulingField(String group, String argument) {
    return group == schedulerGroup && argument == nextRunArg;
  }

  void loadModel(Map<String, dynamic> json) {
    groups.value = [];
    json.forEach((key, value) {
      groups.value.add(GroupsModel(groupName: key, members: value));
    });
  }

  void loadModelfromStr(String json) {
    loadModel(jsonDecode(json));
  }

  Future<void> loadGroups({
    String config = '',
    String task = '',
    bool stagingMode = false,
    List<String> scopeScripts = const [],
    SaveArgumentCallback? saveArgumentOverride,
    SaveArgumentCallback Function(List<String> scopeScripts)?
        saveArgumentFactory,
  }) async {
    final generation = ++_loadGeneration;
    _loadedConfig = config;
    _loadedTask = task;
    updateScopeScripts(scopeScripts, config: config);
    _saveArgumentOverride = saveArgumentOverride;
    _saveArgumentFactory = saveArgumentFactory;
    // Remove the old account's editable fields before starting the next read.
    groupsName.value = [];
    groupsData.value = {};
    groups.value = [];
    isDraftMode.value = stagingMode;
    dirtyFieldKeys.clear();
    fieldErrors.clear();
    _originalValues.clear();

    final groupsMap = <String, GroupsModel>{};
    final names = <String>[];
    final Map<String, dynamic> json;
    try {
      json = await _loadArguments(config, task);
    } catch (_) {
      if (generation != _loadGeneration || isClosed) return;
      rethrow;
    }
    if (generation != _loadGeneration || isClosed) return;
    for (final entry in json.entries) {
      names.add(entry.key);
      final arguments = <ArgumentModel>[];
      for (final argument in entry.value) {
        arguments.add(ArgumentModel.fromJson(argument));
      }
      groupsMap[entry.key] = GroupsModel(
        groupName: entry.key,
        members: arguments,
      );
    }
    groupsData.value = groupsMap;
    groupsName.value = names;
    _snapshotOriginalValues();
    if (!stagingMode || _scopeScripts.length <= 1) {
      return;
    }
  }

  Future<dynamic> getArgValue(
      String config, String task, String group, String argument) {
    if (groupsData.value.isEmpty) {
      loadGroups(config: config, task: task);
    }
    return groupsData.value[group]!.members
        .map((e) => e as ArgumentModel)
        .firstWhere((element) => element.title == argument)
        .value;
  }

  Future<bool> setArgument(String? config, String? task, String group,
      String argument, String type, dynamic value) async {
    if (config == null || task == null || config.isEmpty || task.isEmpty) {
      return false;
    }
    final ret = await ApiClient()
        .putScriptArg(config, task, group, argument, type, value);
    if (ret && group == schedulerGroup) {
      await Get.find<WebSocketService>().send(config, 'get_schedule');
    }
    return ret;
  }

  Future<bool> updateScriptTaskNextRun(
      String config, String task, String nextRun) async {
    return setArgument(
        config, task, schedulerGroup, nextRunArg, 'next_run', nextRun);
  }

  Future<bool> updateScriptTask(String config, String task, bool enable) async {
    return setArgument(
        config, task, schedulerGroup, enableArg, 'boolean', enable);
  }

  void stageArgumentChange(
      String group, String argument, dynamic value, String type) {
    final model = findArgument(group, argument);
    if (model == null) {
      return;
    }
    model.value = value;
    final key = _fieldKey(group, argument);
    if (_isEqualValue(_originalValues[key], value)) {
      dirtyFieldKeys.remove(key);
    } else {
      dirtyFieldKeys.add(key);
    }
    final error = validateArgument(model, value);
    if (error == null || error.isEmpty) {
      fieldErrors.remove(key);
    } else {
      fieldErrors[key] = error;
    }
    if (!dirtyFieldKeys.contains(key)) {
      fieldErrors.remove(key);
    }
    fieldErrors.refresh();
  }

  void discardDraftField(String group, String argument) {
    final key = _fieldKey(group, argument);
    final model = findArgument(group, argument);
    final hasOriginal = _originalValues.containsKey(key);
    var shouldRefreshModel = false;
    if (model != null &&
        hasOriginal &&
        !_isEqualValue(model.value, _originalValues[key])) {
      model.value = _copyValue(_originalValues[key]);
      shouldRefreshModel = true;
    }
    final removedDirty = dirtyFieldKeys.remove(key);
    final removedError = fieldErrors.remove(key) != null;
    if (!shouldRefreshModel && !removedDirty && !removedError) {
      return;
    }
    dirtyFieldKeys.refresh();
    fieldErrors.refresh();
    if (shouldRefreshModel) {
      groups.refresh();
      groupsData.refresh();
    }
  }

  ArgumentModel? findArgument(String group, String argument) {
    final groupModel = groupsData.value[group];
    if (groupModel == null) {
      return null;
    }
    return groupModel.members.cast<ArgumentModel>().firstWhereOrNull(
          (item) => item.title == argument,
        );
  }

  bool isFieldDirty(String group, String argument) {
    return dirtyFieldKeys.contains(_fieldKey(group, argument));
  }

  String? fieldError(String group, String argument) {
    return fieldErrors[_fieldKey(group, argument)];
  }

  bool get hasDraftChanges => dirtyFieldKeys.isNotEmpty;

  String get currentConfig => _loadedConfig;

  String get currentTask => _loadedTask;

  int get draftGeneration => _loadGeneration;

  List<String> get scopeScripts => List.unmodifiable(_scopeScripts);

  void updateScopeScripts(List<String> scopeScripts, {String config = ''}) {
    _scopeScripts = _normalizeScope(scopeScripts, config);
    scopeScriptCount.value = _scopeScripts.isEmpty ? 1 : _scopeScripts.length;
  }

  Future<void> discardDraftChanges() async {
    for (final entry in groupsData.value.entries) {
      for (final member in entry.value.members.cast<ArgumentModel>()) {
        final key = _fieldKey(entry.key, member.title);
        if (_originalValues.containsKey(key)) {
          member.value = _copyValue(_originalValues[key]);
        }
      }
    }
    dirtyFieldKeys.clear();
    fieldErrors.clear();
    groups.refresh();
    groupsData.refresh();
  }

  Future<bool> saveDraftChanges() async {
    if (isSavingDraft.value ||
        !isDraftMode.value ||
        _loadedConfig.isEmpty ||
        _loadedTask.isEmpty) {
      return false;
    }
    final errors = _collectValidationErrors();
    fieldErrors
      ..clear()
      ..addAll(errors);
    fieldErrors.refresh();
    if (errors.isNotEmpty) {
      return false;
    }
    if (dirtyFieldKeys.isEmpty) {
      return true;
    }

    // Snapshot every destination and value before yielding. A later load or
    // edit must never redirect an already started save to the new form.
    final generation = _loadGeneration;
    final source = _loadedConfig;
    final task = _loadedTask;
    final saveArgumentFactory = _saveArgumentFactory;
    final saveArgumentOverride = _saveArgumentOverride;
    final scope = List<String>.unmodifiable(
      _scopeScripts.isEmpty ? [source] : _scopeScripts,
    );
    final writes = <_DraftFieldWrite>[];
    for (final key in dirtyFieldKeys) {
      final field = _decodeFieldKey(key);
      final model = findArgument(field.group, field.argument);
      if (model != null) {
        writes.add(
          _DraftFieldWrite(key, field, model.type, _copyValue(model.value)),
        );
      }
    }
    isSavingDraft.value = true;
    var allSuccess = true;
    try {
      final override =
          saveArgumentFactory?.call(scope) ?? saveArgumentOverride;
      final persist = override ?? setArgument;
      final targets = override == null ? scope : [source];
      for (final write in writes) {
        var fieldSuccess = true;
        for (final config in targets) {
          final ret = await persist(
            config,
            task,
            write.field.group,
            write.field.argument,
            write.type,
            _copyValue(write.value),
          );
          fieldSuccess = ret && fieldSuccess;
        }
        allSuccess = fieldSuccess && allSuccess;
        if (fieldSuccess && generation == _loadGeneration && !isClosed) {
          _originalValues[write.key] = _copyValue(write.value);
          final current = findArgument(write.field.group, write.field.argument);
          if (current != null) {
            // A user can continue editing while the previous value is saved.
            // Recompute dirtiness against the value actually sent, not current.
            stageArgumentChange(
              write.field.group,
              write.field.argument,
              current.value,
              current.type,
            );
          }
        }
      }
      return allSuccess;
    } finally {
      isSavingDraft.value = false;
    }
  }

  String? validateArgument(ArgumentModel model, dynamic value) {
    final current = value?.toString() ?? '';
    return switch (model.type) {
      'integer' => _validateInteger(model, current),
      'number' => _validateNumber(model, current),
      'date_time' =>
        _dateTimePattern.hasMatch(current) ? null : I18n.argsInvalidDateTime.tr,
      'time' => _timePattern.hasMatch(current) ? null : I18n.argsInvalidTime.tr,
      'time_delta' => _timeDeltaPattern.hasMatch(current)
          ? null
          : I18n.argsInvalidTimeDelta.tr,
      'enum' => _validateEnum(model, current),
      'multi_enum' => value is List && value.isNotEmpty &&
          value.every((item) => (model.enumEnum ?? const <String>[]).contains(item))
          ? null : I18n.argsInvalidEnum.tr,
      _ => null,
    };
  }

  Map<String, String> _collectValidationErrors() {
    final errors = <String, String>{};
    for (final entry in groupsData.value.entries) {
      for (final model in entry.value.members.cast<ArgumentModel>()) {
        final error = validateArgument(model, model.value);
        if (error != null && error.isNotEmpty) {
          errors[_fieldKey(entry.key, model.title)] = error;
        }
      }
    }
    return errors;
  }

  List<String> _normalizeScope(List<String> raw, String config) {
    final result = raw
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (config.isNotEmpty && !result.contains(config)) {
      result.insert(0, config);
    }
    return result;
  }

  void _snapshotOriginalValues() {
    for (final entry in groupsData.value.entries) {
      for (final model in entry.value.members.cast<ArgumentModel>()) {
        _originalValues[_fieldKey(entry.key, model.title)] = _copyValue(
          model.value,
        );
      }
    }
  }

  bool _isEqualValue(dynamic left, dynamic right) {
    return left?.toString() == right?.toString();
  }

  dynamic _copyValue(dynamic value) {
    if (value is List) return value.map(_copyValue).toList();
    if (value is Map) {
      return value.map((key, item) => MapEntry(key, _copyValue(item)));
    }
    return value;
  }

  String _fieldKey(String group, String argument) {
    return '$group::$argument';
  }

  _FieldDescriptor _decodeFieldKey(String value) {
    final parts = value.split('::');
    return _FieldDescriptor(
      group: parts.first,
      argument: parts.length > 1 ? parts[1] : '',
    );
  }

  String? _validateEnum(ArgumentModel model, String value) {
    final options = model.enumEnum ?? const <String>[];
    if (options.isEmpty || options.contains(value)) {
      return null;
    }
    return I18n.argsInvalidEnum.tr;
  }

  String? _validateInteger(ArgumentModel model, String value) {
    final parsed = int.tryParse(value);
    if (parsed == null) {
      return I18n.argsInvalidInteger.tr;
    }
    final minimum = _numValue(model.minimum);
    if (minimum != null && parsed < minimum) {
      return '${I18n.argsMinValue.tr} $minimum';
    }
    final maximum = _numValue(model.maximum);
    if (maximum != null && parsed > maximum) {
      return '${I18n.argsMaxValue.tr} $maximum';
    }
    return null;
  }

  String? _validateNumber(ArgumentModel model, String value) {
    final parsed = num.tryParse(value);
    if (parsed == null) {
      return I18n.argsInvalidNumber.tr;
    }
    final minimum = _numValue(model.minimum);
    if (minimum != null && parsed < minimum) {
      return '${I18n.argsMinValue.tr} $minimum';
    }
    final maximum = _numValue(model.maximum);
    if (maximum != null && parsed > maximum) {
      return '${I18n.argsMaxValue.tr} $maximum';
    }
    return null;
  }

  num? _numValue(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value;
    }
    return num.tryParse(value.toString());
  }
}

class GroupsModel {
  final String groupName;
  List<dynamic> members;

  GroupsModel({required this.groupName, required this.members});

  String getGroupName() => groupName;
}

class ArgumentModel {
  final String title;
  dynamic value;
  final String type;
  final String? description;
  final List<String>? enumEnum;
  final dynamic minimum;
  final dynamic maximum;
  final dynamic defaultValue;

  ArgumentModel(
    this.enumEnum,
    this.minimum,
    this.maximum,
    this.defaultValue,
    this.description, {
    required this.title,
    required this.value,
    required this.type,
  });

  factory ArgumentModel.fromJson(Map<String, dynamic> json) {
    return ArgumentModel(
      List<String>.from(json['enumEnum']?.map((item) => item) ?? []),
      json['minimum'],
      json['maximum'],
      json['defaultValue'],
      json['description'],
      title: json['name'] as String,
      value: json['value'],
      type: json['type'] as String,
    );
  }

  set setValue(dynamic newValue) => value = newValue;
}

class _FieldDescriptor {
  const _FieldDescriptor({required this.group, required this.argument});

  final String group;
  final String argument;
}

class _DraftFieldWrite {
  const _DraftFieldWrite(this.key, this.field, this.type, this.value);

  final String key;
  final _FieldDescriptor field;
  final String type;
  final dynamic value;
}
