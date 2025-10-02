import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';
import 'url.dart';
import '../utility/notification.dart';
import 'dart:developer' as developer;

class ImageCacheConfig {
  final Duration cacheDuration;
  final int maxCacheItems;
  final int maxCacheSizeBytes;

  const ImageCacheConfig({
    this.cacheDuration = const Duration(days: 7),
    this.maxCacheItems = 1000,
    this.maxCacheSizeBytes = 100 * 1024 * 1024, // 100MB
  });
}

class ApiClient {
  final http.Client _client;
  final BuildContext _context;
  late final CacheManager _cacheManager;
  final _imageCache = <String, Completer<File>>{};
  final _downloadQueue = <String>[];
  bool _isProcessingQueue = false;
  final ImageCacheConfig config;

  final _lock = Lock();
  final _activeDownloads = <String>{};
  static const int _maxConcurrentDownloads = 3;

  ApiClient(this._client, this._context, {this.config = const ImageCacheConfig()}) {
    _initializeCacheManager();
    _startPeriodicCacheCleanup();
  }

  Future<void> _initializeCacheManager() async {
    _cacheManager = await _createCustomCacheManager();
  }

  Future<CacheManager> _createCustomCacheManager() async {
    final directory = await getTemporaryDirectory();
    return CacheManager(
      Config(
        'advancedImageCache',
        stalePeriod: config.cacheDuration,
        maxNrOfCacheObjects: config.maxCacheItems,
        repo: JsonCacheInfoRepository(
          databaseName: 'advanced_image_cache_db',
        ),
        fileSystem: IOFileSystem(directory.path),
        fileService: HttpFileService(),
      ),
    );
  }

  void _startPeriodicCacheCleanup() {
    Timer.periodic(const Duration(hours: 6), (_) => _performCacheCleanup());
  }

  Future<void> _performCacheCleanup() async {
    try {
      final cacheSize = await getCachedImagesSize();
      if (cacheSize > config.maxCacheSizeBytes) {
        await _cacheManager.emptyCache();
      }
    } catch (e) {
      _logError('Cache cleanup failed: $e');
    }
  }

  Future<File> fetchImage(String imageUrl, {bool forceFetch = false}) async {
    return await _lock.synchronized(() async {
      // Check if download is already in progress
      if (_imageCache.containsKey(imageUrl)) {
        return _imageCache[imageUrl]!.future;
      }

      final completer = Completer<File>();
      _imageCache[imageUrl] = completer;

      try {
        if (!forceFetch) {
          // Try to get from disk cache
          final cachedFile = await _getCachedFile(imageUrl);
          if (cachedFile != null) {
            completer.complete(cachedFile);
            _imageCache.remove(imageUrl);
            return cachedFile;
          }
        }

        // Add to download queue if not connected or too many active downloads
        if (!(await _hasInternetConnection()) || _activeDownloads.length >= _maxConcurrentDownloads) {
          _addToDownloadQueue(imageUrl);
          return completer.future;
        }

        // Download the image
        final file = await _downloadImage(imageUrl);
        completer.complete(file);
        _imageCache.remove(imageUrl);
        return file;
      } catch (e) {
        _imageCache.remove(imageUrl);
        completer.completeError(e);
        rethrow;
      }
    });
  }

  Future<File?> _getCachedFile(String imageUrl) async {
    try {
      final fileInfo = await _cacheManager.getFileFromCache(imageUrl);
      if (fileInfo != null && await fileInfo.file.exists()) {
        return fileInfo.file;
      }
    } catch (e) {
      _logError('Cache retrieval failed: $e');
    }
    return null;
  }

  Future<File> _downloadImage(String imageUrl) async {
    _activeDownloads.add(imageUrl);
    try {
      final fileInfo = await _cacheManager.downloadFile(
        imageUrl,
        key: imageUrl,
        force: true,
      );
      return fileInfo.file;
    } finally {
      _activeDownloads.remove(imageUrl);
      _processDownloadQueue();
    }
  }

  void _addToDownloadQueue(String imageUrl) {
    if (!_downloadQueue.contains(imageUrl)) {
      _downloadQueue.add(imageUrl);
      if (!_isProcessingQueue) {
        _processDownloadQueue();
      }
    }
  }

  Future<void> _processDownloadQueue() async {
    if (_isProcessingQueue || _downloadQueue.isEmpty) return;

    _isProcessingQueue = true;
    try {
      while (_downloadQueue.isNotEmpty && _activeDownloads.length < _maxConcurrentDownloads) {
        final url = _downloadQueue.removeAt(0);
        if (_imageCache.containsKey(url)) {
          if (await _hasInternetConnection()) {
            unawaited(_downloadImage(url).then((file) {
              _imageCache[url]?.complete(file);
              _imageCache.remove(url);
            }).catchError((error) {
              _imageCache[url]?.completeError(error);
              _imageCache.remove(url);
            }));
          }
        }
      }
    } finally {
      _isProcessingQueue = false;
    }
  }

  Future<void> prefetchImages(List<String> imageUrls) async {
    if (!(await _hasInternetConnection())) return;

    final batch = imageUrls.take(_maxConcurrentDownloads).toList();
    final remaining = imageUrls.skip(_maxConcurrentDownloads).toList();

    await Future.wait(
      batch.map((url) => fetchImage(url)),
    );

    if (remaining.isNotEmpty) {
      await prefetchImages(remaining);
    }
  }

  Future<void> clearCache() async {
    await _cacheManager.emptyCache();
  }

  Future<int> getCachedImagesSize() async {
    try {
      final directory = await getTemporaryDirectory();
      int totalSize = 0;
      await for (var entity in directory.list(recursive: true)) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      return totalSize;
    } catch (e) {
      _logError('Failed to calculate cache size: $e');
      return 0;
    }
  }

  // HTTP Request Methods
  Future<http.Response> request(
      String endpoint, {
        required String method,
        Map<String, String>? data,
        Map<String, String>? headers,
        Map<String, File>? files, // Add support for file uploads
        int retryCount = 3,
      }) async {
    final uri = Uri.parse('${ApiConstants.baseUrl}$endpoint');
    final requestHeaders = {
      'Authorization': '3cc61939065188f6cee59d4aae99e34e9cbcb24ccf76301c4bd88919e3afde7e',
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': '*/*',
      ...?headers,
    };

    _logRequest(method, uri, requestHeaders, data);

    if (!(await _hasInternetConnection())) {
      _logError('No internet connection');
      showRetryNotification(_context, 'No internet connection', onRetry: () {
        request(endpoint, method: method, data: data, headers: headers, files: files);
      });
      throw const SocketException('No internet connection');
    }

    try {
      final response = await _performRequest(method, uri, requestHeaders, data, files);
      _logResponse(response);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      } else {
        _handleErrorResponse(response, method, endpoint, data, headers, retryCount);
        throw HttpException('Error ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      _logError('Request failed: $e');
      if (retryCount > 0) {
        await Future.delayed(const Duration(seconds: 1));
        return request(
          endpoint,
          method: method,
          data: data,
          headers: headers,
          files: files,
          retryCount: retryCount - 1,
        );
      }
      rethrow;
    }
  }

  Future<http.Response> _performRequest(
      String method,
      Uri uri,
      Map<String, String> headers,
      Map<String, String>? data,
      Map<String, File>? files,
      ) async {
    if (files != null && files.isNotEmpty) {
      // Create a multipart request for file uploads
      final request = http.MultipartRequest(method, uri);

      // Add headers
      request.headers.addAll(headers);

      // Add fields
      if (data != null) {
        request.fields.addAll(data);
      }

      // Add files
      for (final entry in files.entries) {
        final file = entry.value;
        request.files.add(await http.MultipartFile.fromPath(entry.key, file.path));
      }

      // Send the request
      final streamedResponse = await request.send();
      return await http.Response.fromStream(streamedResponse);
    } else {
      // Send a regular request (without files)
      switch (method.toUpperCase()) {
        case 'POST':
          return await _client.post(uri, headers: headers, body: data);
        case 'GET':
          return await _client.get(uri, headers: headers);
        case 'PUT':
          return await _client.put(uri, headers: headers, body: data);
        case 'DELETE':
          return await _client.delete(uri, headers: headers, body: data);
        default:
          throw ArgumentError('Invalid HTTP method: $method');
      }
    }
  }

  void _handleErrorResponse(http.Response response, String method, String endpoint, Map<String, String>? data, Map<String, String>? headers, int retryCount) {
    String errorMessage;
    switch (response.statusCode) {
      case 400:
        errorMessage = 'Bad Request: ${response.body}';
        break;
      case 401:
        errorMessage = 'Unauthorized: ${response.body}';
        break;
      case 404:
        errorMessage = 'Not Found: ${response.body}';
        break;
      default:
        errorMessage = 'Server error: ${response.statusCode}';
    }
    _logError(errorMessage);
    showRetryNotification(_context, errorMessage, onRetry: () {
      request(endpoint, method: method, data: data, headers: headers, retryCount: retryCount - 1);
    });
  }

  Future<bool> _hasInternetConnection() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) return false;

      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  void _logRequest(String method, Uri uri, Map<String, String> headers, Map<String, String>? data) {
    //developer.log('API Request:', name: 'ApiClient');
    //developer.log('Method: $method', name: 'ApiClient');
    //developer.log('URL: $uri', name: 'ApiClient');
  }

  void _logResponse(http.Response response) {
    //developer.log('API Response:', name: 'ApiClient');
    //developer.log('Status Code: ${response.statusCode}', name: 'ApiClient');
  }

  void _logError(String message) {
    //developer.log('Error: $message', name: 'ApiClient', error: message);
  }
}