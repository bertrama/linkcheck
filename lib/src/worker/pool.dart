library linkcheck.pool;

import 'dart:async';

import '../destination.dart';
import '../server_info.dart';
import 'fetch_results.dart';
import 'worker.dart';

class Pool {
  /// How much time before we kill a [Worker].
  ///
  /// This should give it enough time for the HttpClient [fetchTimeout]
  /// plus buffer for actual Dart code.
  static final workerTimeout = fetchTimeout + const Duration(milliseconds: 500);
  static const healthCheckFrequency = const Duration(seconds: 1);

  /// The number of threads.
  final int count;

  bool _isShuttingDown = false;
  List<Worker> _workers;

  Timer _healthCheckTimer;

  Map<Worker, DateTime> _lastJobPosted = new Map<Worker, DateTime>();
  final Set<String> _hostGlobs;

  StreamController<FetchResults> _fetchResultsSink =
      new StreamController<FetchResults>();

  Stream<FetchResults> fetchResults;

  StreamController<String> _messagesSink = new StreamController<String>();

  Stream<String> messages;

  StreamController<ServerInfoUpdate> _serverCheckSink =
      new StreamController<ServerInfoUpdate>();

  Stream<ServerInfoUpdate> serverCheckResults;

  bool _finished = false;

  Pool(this.count, this._hostGlobs) {
    fetchResults = _fetchResultsSink.stream;
    messages = _messagesSink.stream;
    serverCheckResults = _serverCheckSink.stream;
  }

  /// Returns true if all workers are either waiting for a job or not really
  /// alive (not spawned yet, or already killed).
  bool get allIdle => _workers
      .every((worker) => worker.idle || !worker.spawned || worker.isKilled);

  bool get anyIdle => _workers.any((worker) => worker.idle);

  bool get allBusy => !anyIdle;

  bool get finished => _finished;

  bool get isShuttingDown => _isShuttingDown;

  /// Asks a worker to check the given [destination]. Waits [delay] before
  /// doing so.
  Worker checkPage(Destination destination, Duration delay) {
    var worker = pickWorker();
    _lastJobPosted[worker] = new DateTime.now();
    worker.destinationToCheck = destination;
    new Timer(delay, () {
      if (_isShuttingDown) return;
      worker.sink.add({verbKey: checkPageVerb, dataKey: destination.toMap()});
    });
    return worker;
  }

  /// Starts a job to send request for /robots.txt on the server.
  Worker checkServer(String host) {
    var worker = pickWorker();
    worker.sink.add({verbKey: checkServerVerb, dataKey: host});
    worker.serverToCheck = host;
    _lastJobPosted[worker] = new DateTime.now();
    return worker;
  }

  Future<Null> close() async {
    _isShuttingDown = true;
    _healthCheckTimer.cancel();
    await Future.wait(_workers.map((worker) async {
      if (!worker.spawned || worker.isKilled) return;
      await worker.kill();
    }));
    _finished = true;
  }

  /// Finds the worker with the least amount of jobs.
  Worker pickWorker() {
    for (var worker in _workers) {
      if (worker.spawned && worker.idle) return worker;
    }
    throw new StateError("Attempt to use Pool when all workers are busy. "
        "Please make sure to wait until Pool.allWorking is false.");
  }

  Future<Null> spawn() async {
    _workers =
        new List<Worker>.generate(count, (i) => new Worker()..name = '$i');
    await Future.wait(_workers.map((worker) => worker.spawn()));
    _workers.forEach((worker) => worker.stream.listen((Map message) {
          switch (message[verbKey]) {
            case checkPageDoneVerb:
              var result = new FetchResults.fromMap(
                  message[dataKey] as Map<String, Object>);
              _fetchResultsSink.add(result);
              worker.destinationToCheck = null;
              return;
            case checkServerDoneVerb:
              var result = new ServerInfoUpdate.fromMap(
                  message[dataKey] as Map<String, Object>);
              _serverCheckSink.add(result);
              worker.serverToCheck = null;
              return;
            case infoFromWorkerVerb:
              _messagesSink.add(message[dataKey]);
              return;
            default:
              throw new StateError("Unrecognized verb from Worker: "
                  "${message[verbKey]}");
          }
        }));
    _addHostGlobs();

    _healthCheckTimer = new Timer.periodic(healthCheckFrequency, (_) async {
      if (_isShuttingDown) return null;
      var now = new DateTime.now();
      for (int i = 0; i < _workers.length; i++) {
        var worker = _workers[i];
        if (!worker.idle &&
            !worker.isKilled &&
            _lastJobPosted[worker] != null &&
            now.difference(_lastJobPosted[worker]) > workerTimeout) {
          _messagesSink.add("Killing unresponsive $worker");
          var destination = worker.destinationToCheck;
          var server = worker.serverToCheck;

          _lastJobPosted.remove(worker);
          var newWorker = new Worker()..name = '$i';
          _workers[i] = newWorker;

          if (destination != null) {
            // Only notify about the failed destination when the old
            // worker is gone. Otherwise, crawl could fail to wrap up, thinking
            // that one Worker is still working.
            var checked = new DestinationResult.fromDestination(destination);
            checked.didNotConnect = true;
            var result = new FetchResults(checked, const []);
            _fetchResultsSink.add(result);
          }

          if (server != null) {
            var result = new ServerInfoUpdate(server);
            result.didNotConnect = true;
            _serverCheckSink.add(result);
          }

          await newWorker.spawn();
          if (_isShuttingDown) {
            // The pool has been closed in the time it took to spawn this
            // worker.
            await newWorker.kill();
          }
          await worker.kill();
        }
      }
    });
  }

  /// Sends host globs (e.g. http://example.com/**) to all the workers.
  void _addHostGlobs() {
    for (var worker in _workers) {
      worker.sink.add({verbKey: addHostGlobVerb, dataKey: _hostGlobs.toList()});
    }
  }
}
