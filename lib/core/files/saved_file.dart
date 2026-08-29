/// Where an edited document ended up, in terms the UI can show the user.
class SavedFile {
  const SavedFile({required this.name, required this.location, this.path});

  /// The file name as saved.
  final String name;

  /// Human-readable place: a full path on desktop and mobile, or the browser's
  /// download location on web, where the page never learns the real path.
  final String location;

  /// The on-disk path, when there is one. Null on web.
  final String? path;
}
