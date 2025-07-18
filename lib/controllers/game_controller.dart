import 'dart:async';
import 'dart:math';

import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hand_cricket/core/contstants/app_constants.dart';
import 'package:hand_cricket/models/game_player.dart';
import 'package:hand_cricket/models/game_room.dart';
import 'package:hand_cricket/services/auth_service.dart';
import 'package:hand_cricket/services/game_firestore_service.dart';

class GameController extends StateNotifier<GameState> {
  final AuthService authService;
  final GameFirestoreService gameFirestoreService;
  Timer? _gameTimer;
  Timer? _moveTimer;
  Timer? _startTimer;
  Timer? _waitingTimer;

  // Pause/Resume state variables
  int _pausedMainTimer = 0;
  GamePhase? _pausedPhase;
  MoveStatus? _pausedMoveStatus;

  var opponentMove = 0;

  GameController({
    required this.authService,
    required this.gameFirestoreService,
  }) : super(GameInitial());

  @override
  void dispose() {
    _gameTimer?.cancel();
    _moveTimer?.cancel();
    _startTimer?.cancel();
    _waitingTimer?.cancel();
    gameFirestoreService.dispose();
    super.dispose();
  }

  void initializeGame(GameMode mode) async {
    // Get current user from auth service
    final user = await authService.getCurrentUser();
    if (user == null) {
      state = GameError('User not authenticated');
      return;
    }

    // Do toss
    final toss =
        Random().nextBool(); // true for batting first, false for bowling first

    final player = GamePlayer(
      uid: user.uid,
      name: user.name ?? 'Guest',
      avatarUrl: user.avatar ?? AppConstants.avatarUrl,
      type: PlayerType.player1,
      isBatting: toss,
    );

    if (mode == GameMode.practice) {
      // computer
      final computer = GamePlayer(
        uid: 'computer',
        name: 'Computer',
        avatarUrl: AppConstants.computerAvatarUrl,
        type: PlayerType.computer,
        isBatting: !toss, // Computer bats opposite to player
      );

      state = GameWaiting(
        player: player,
        opponent: computer,
        mode: mode,
        mainTimer: 3,
        message: 'Game Starts in...',
        toss: toss,
        status: GameWaitingStatus.matched,
      );

      _startGameCountdown();
    } else {
      // ONLINE MODE

      state = GameWaiting(
        player: player,
        message: 'Waiting for opponent...',
        status: GameWaitingStatus.wait,
        toss: toss,
        mode: mode,
      );

      // start waiting timer
      _startWaitingTimer();

      _startMatching();
    }
  }

  void _startWaitingTimer() {
    if (state is! GameWaiting) return;

    int countdown = 60;
    _waitingTimer?.cancel();
    _waitingTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (state is! GameWaiting) {
        timer.cancel();
        return;
      }
      countdown--;
      if (countdown < 0) {
        // timed out
        timer.cancel();
        final currentState = state as GameWaiting;
        state = currentState.copyWith(
          status: GameWaitingStatus.timedOut,
          message: 'Could not any match yet!',
        );
      }
    });
  }

  void _startMatching() async {
    if (state is! GameWaiting) return;

    final currentState = state as GameWaiting;

    final room = await gameFirestoreService.checkAvailableGameRoom();

    if (room == null) {
      // create a room
      final room = GameRoom(
        id: 'temp',
        phase: GamePhase.waiting,
        player1: currentState.player,
        whoBattingFirst:
            currentState.toss ? PlayerType.player1 : PlayerType.player2,
        status: GameStatus.waiting,
      );
      final newRoom = await gameFirestoreService.createGameRoom(room);

      // update state with new room data
      state = currentState.copyWith(roomId: newRoom.id);

      // start listening opponent matching from firestore
      gameFirestoreService.listeningGameRoom(newRoom.id);
      _listenGameRoom();

      //
    } else {
      // join a room

      // change player type
      final player = currentState.player.copyWith(
        type: PlayerType.player2,
        isBatting: room.whoBattingFirst == PlayerType.player2,
      );
      final gameRoom = room.copyWith(
        player2: player,
        status: GameStatus.active,
        phase: GamePhase.toss,
      );
      await gameFirestoreService.joinGameRoom(gameRoom);

      // update state with opponent and player with updated player type
      state = currentState.copyWith(
        player: player,
        opponent: gameRoom.player1,
        status: GameWaitingStatus.matched,
        mainTimer: 3,
        roomId: room.id,
        toss: room.whoBattingFirst == PlayerType.player2,
        message: 'You are matched...',
      );

      // after matched cancel waiting timer
      _waitingTimer?.cancel();

      _startGameCountdown();
    }
  }

  void _listenGameRoom() {
    gameFirestoreService.roomStream.listen((room) {
      // state is game waiting -> update opponent and match starts
      if (state is GameWaiting && room.player2 != null) {
        _updateOpponentMatched(room);
      }

      // state is game started -> update game status - move, opponent
      if (state is GameStarted) {
        final currentState = state as GameStarted;
        if (room.player2 != null) {
          opponentMove = room.player2choice;
          state = currentState.copyWith(opponent: room.player2);
        }
      }
    });
  }

  void _updateOpponentMatched(GameRoom room) {
    if (state is! GameWaiting) return;

    final currentState = state as GameWaiting;
    if (room.player2 == null && currentState.roomId != room.id) return;

    state = currentState.copyWith(
      opponent: room.player2,
      status: GameWaitingStatus.matched,
      mainTimer: 3,
      roomId: room.id,
      message: 'You are matched...',
    );

    // after matched cancel waiting timer
    _waitingTimer?.cancel();

    _startGameCountdown();
  }

  void _startGameCountdown() {
    if (state is! GameWaiting) return;

    final currentState = state as GameWaiting;

    _startTimer?.cancel();
    int countdown = 3;
    _startTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (state is! GameWaiting) {
        timer.cancel();
        return;
      }
      countdown--;
      if (countdown < 0) {
        timer.cancel();
        print('Countdown  - Starting Game...');
        _startingGame();
      } else {
        final newState = currentState.copyWith(
          mainTimer: countdown,
          message: 'Game Starts in...',
        );

        state = newState;
      }
    });
  }

  void _startingGame() {
    if (state is! GameWaiting) return;

    final currentState = state as GameWaiting;

    state = currentState.copyWith(status: GameWaitingStatus.started);
  }

  void startGame() async {
    if (state is! GameWaiting) return;

    final currentState = state as GameWaiting;

    state = GameStarted(
      phase: GamePhase.toss,
      player: currentState.player,
      opponent: currentState.opponent!,
      isBattingFirst: currentState.toss,
      message:
          currentState.toss ? 'You\'re batting first' : 'You\'re bowling first',
      moveChoice: 0,
      opponentChoice: 0,
      moveStatus: MoveStatus.start,
      mode: currentState.mode,
      roomId: currentState.roomId,
      isPaused: false,
    );

    // Start innigs countdown
    _startInningsCountdown(GamePhase.innings1);
  }

  void pauseGame() {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;

    // Don't pause if game is already paused, ended, or in result phase
    if (currentState.isPaused ||
        currentState.phase == GamePhase.result ||
        currentState.moveStatus == MoveStatus.end) {
      return;
    }

    _pausedMainTimer = currentState.mainTimer;
    _pausedPhase = currentState.phase;
    _pausedMoveStatus = currentState.moveStatus;

    // Cancel any running timers
    _gameTimer?.cancel();
    _moveTimer?.cancel();

    state = currentState.copyWith(
      isPaused: true,
      message: 'Game Paused',
      moveStatus: MoveStatus.paused,
    );
  }

  void resumeGame() {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;

    // Only resume if game is paused
    if (!currentState.isPaused) return;

    // Restore the game state
    state = currentState.copyWith(
      isPaused: false,
      mainTimer: _pausedMainTimer,
      phase: _pausedPhase ?? currentState.phase,
      moveStatus: _pausedMoveStatus ?? currentState.moveStatus,
      message: _getResumeMessage(),
    );

    // Resume appropriate timer based on the paused phase and status
    if (_pausedPhase == GamePhase.startInnigs) {
      _resumeInningsCountdown();
    } else if ((_pausedPhase == GamePhase.innings1 ||
            _pausedPhase == GamePhase.innings2) &&
        (_pausedMoveStatus == MoveStatus.next ||
            _pausedMoveStatus == MoveStatus.wait)) {
      _resumeMoveTimer();
    }

    // Clear pause state
    _pausedMainTimer = 0;
    _pausedPhase = null;
    _pausedMoveStatus = null;
  }

  String _getResumeMessage() {
    if (_pausedPhase == GamePhase.startInnigs) {
      return 'Game resumed! Get ready...';
    } else if (_pausedPhase == GamePhase.innings1 ||
        _pausedPhase == GamePhase.innings2) {
      if (state is GameStarted) {
        final currentState = state as GameStarted;
        return currentState.player.isBatting
            ? 'Game resumed! Choose your move!'
            : 'Game resumed! Stop the computer!';
      }
    }
    return 'Game resumed!';
  }

  void _resumeInningsCountdown() {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;
    int countdown = _pausedMainTimer;

    GamePhase targetPhase =
        currentState.isBattingFirst
            ? (currentState.player.ballsFaced == 6 || currentState.player.isOut
                ? GamePhase.innings2
                : GamePhase.innings1)
            : (currentState.opponent.ballsFaced == 6 ||
                    currentState.opponent.isOut
                ? GamePhase.innings2
                : GamePhase.innings1);

    _gameTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (state is! GameStarted) {
        timer.cancel();
        return;
      }

      final current = state as GameStarted;
      if (current.isPaused) {
        timer.cancel();
        return;
      }

      countdown--;

      if (countdown < 0) {
        timer.cancel();
        _startInnings(targetPhase);
      } else {
        state = current.copyWith(mainTimer: countdown);
      }
    });
  }

  void exitGame() {
    _gameTimer?.cancel();
    _moveTimer?.cancel();
    _startTimer?.cancel();
    _waitingTimer?.cancel();
    _pausedMainTimer = 0;
    _pausedPhase = null;
    _pausedMoveStatus = null;
    state = GameInitial();
  }

  void _resumeMoveTimer() {
    if (state is! GameStarted) return;

    int countdown = _pausedMainTimer;

    _moveTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (state is! GameStarted) {
        timer.cancel();
        return;
      }

      final current = state as GameStarted;
      if (current.isPaused) {
        timer.cancel();
        return;
      }

      countdown--;

      if (countdown < 0) {
        timer.cancel();
        _processMoves(current.moveChoice);
      } else {
        state = current.copyWith(
          mainTimer: countdown,
          moveStatus: MoveStatus.wait,
        );
      }
    });
  }

  void _startInningsCountdown(GamePhase phase) {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;
    int countdown = 3;
    int? target;
    String message;

    if (phase == GamePhase.innings2) {
      target =
          currentState.isBattingFirst
              ? currentState.player.score + 1
              : currentState.opponent.score + 1;

      message =
          currentState.isBattingFirst
              ? 'Now it\'s your turn to bowl! Defend $target'
              : 'Now it\'s your turn to bat! Target $target';
    } else {
      message =
          currentState.isBattingFirst
              ? 'You\'re batting first'
              : 'You\'re bowling first';
    }

    state = currentState.copyWith(
      message: message,
      target: target,
      mainTimer: countdown,
      phase: GamePhase.startInnigs,
    );

    _gameTimer?.cancel();
    _gameTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (state is! GameStarted) {
        timer.cancel();
        return;
      }

      final current = state as GameStarted;
      if (current.isPaused) {
        timer.cancel();
        return;
      }

      countdown--;

      if (countdown < 0) {
        timer.cancel();
        // Move to innings
        _startInnings(phase);
      } else {
        state = current.copyWith(
          mainTimer: countdown,
          phase: GamePhase.startInnigs,
          message: message,
          target: target,
        );
      }
    });
  }

  void _startInnings(GamePhase phase) async {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;

    int? target;
    GamePlayer updatedPlayer = currentState.player;
    GamePlayer updatedOpponent = currentState.opponent;

    if (phase == GamePhase.innings2) {
      // Switch batting/bowling for innings 2
      updatedPlayer = currentState.player.copyWith(
        isBatting: !currentState.player.isBatting,
      );
      updatedOpponent = currentState.opponent.copyWith(
        isBatting: !currentState.opponent.isBatting,
      );

      target =
          currentState.isBattingFirst
              ? currentState.player.score + 1
              : currentState.opponent.score + 1;
    }

    // update game room only for online mode
    if (currentState.mode == GameMode.online && currentState.roomId != null) {
      gameFirestoreService.updateGameRoom(
        id: currentState.roomId!,
        player: updatedPlayer,
        target: target,
        choice: 0,
        phase: phase,
      );
    }

    state = currentState.copyWith(
      phase: phase,
      player: updatedPlayer,
      opponent: updatedOpponent,
      message: 'Choose a number!',
      moveChoice: 0,
      opponentChoice: 0,
      target: target,
      moveStatus: MoveStatus.next,
    );

    _startMoveTimer();
  }

  void _startMoveTimer() {
    if (state is! GameStarted) return;
    int countdown = 5;

    _moveTimer?.cancel();
    _moveTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (state is! GameStarted) {
        timer.cancel();
        return;
      }

      final current = state as GameStarted;
      if (current.isPaused) {
        timer.cancel();
        return;
      }

      countdown--;

      if (countdown < 0) {
        timer.cancel();
        // Auto-select 0 move if player didn't choose
        _processMoves(current.moveChoice);
      } else {
        state = current.copyWith(
          mainTimer: countdown,
          moveStatus: MoveStatus.wait,
        );
      }
    });
  }

  void chooseMove(int moveChoice) {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;

    // Don't allow move selection if game is paused
    if (currentState.isPaused) return;

    // Only allow move selection during innings and when not in progress
    if ((currentState.phase == GamePhase.innings1 ||
            currentState.phase == GamePhase.innings2) &&
        currentState.moveStatus != MoveStatus.progress) {
      // update choice in game room
      if (currentState.mode == GameMode.online && currentState.roomId != null) {
        gameFirestoreService.updateGameRoom(
          id: currentState.roomId!,
          choice: moveChoice,
          player: currentState.player,
        );
      }
      state = currentState.copyWith(
        moveChoice: moveChoice,
        message:
            currentState.mode == GameMode.online
                ? 'Waiting for opponent...'
                : currentState.message,
      );

      // If timer is running and move is selected, process immediately only in practice mode
      if (currentState.mode == GameMode.practice &&
          currentState.mainTimer > 0) {
        _moveTimer?.cancel();
        _processMoves(moveChoice);
      }
    }
  }

  void _processMoves(int playerChoice) {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;
    final opponentChoice =
        currentState.mode == GameMode.online
            ? opponentMove
            : Random().nextInt(6) + 1;

    // Set moves and progress status
    state = currentState.copyWith(
      moveChoice: playerChoice,
      opponentChoice: opponentChoice,
      moveStatus: MoveStatus.progress,
      mainTimer: 0,
    );

    //process result
    _processResult(playerChoice, opponentChoice);
  }

  void _processResult(int playerMove, int opponentMove) {
    if (state is! GameStarted) return;

    if (playerMove == opponentMove) {
      // OUT!
      _handleOut();
    } else {
      // Runs scored
      _handleRuns(playerMove, opponentMove);
    }
  }

  void _handleOut() {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;

    if (currentState.player.isBatting) {
      // Player is out
      final updatedPlayer = currentState.player.copyWith(
        isOut: true,
        ballsFaced: currentState.player.ballsFaced + 1,
      );

      // update player on game room
      if (currentState.mode == GameMode.online && currentState.roomId != null) {
        gameFirestoreService.updateGameRoom(
          id: currentState.roomId!,
          player: updatedPlayer,
        );
      }

      state = currentState.copyWith(
        player: updatedPlayer,
        message: 'Oh no! You are out!',
        moveStatus: MoveStatus.progressed,
      );
    } else {
      // Opponent is out
      final updatedOpponent = currentState.opponent.copyWith(
        isOut: true,
        ballsFaced: currentState.opponent.ballsFaced + 1,
      );

      state = currentState.copyWith(
        opponent: updatedOpponent,
        message: 'Yay! Bowled them out!',
        moveStatus: MoveStatus.progressed,
      );
    }

    // Continue game after delay
    Timer(Duration(seconds: 2), () {
      _checkInningsEnd();
    });
  }

  void _handleRuns(int playerMove, int opponentMove) {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;

    if (currentState.player.isBatting) {
      // Player is batting
      final updatedPlayer = currentState.player.copyWith(
        score: currentState.player.score + playerMove,
        ballsFaced: currentState.player.ballsFaced + 1,
      );

      // update player on game room
      if (currentState.mode == GameMode.online && currentState.roomId != null) {
        gameFirestoreService.updateGameRoom(
          id: currentState.roomId!,
          player: updatedPlayer,
        );
      }

      state = currentState.copyWith(
        player: updatedPlayer,
        message: _getScoreMessage(playerMove),
        moveStatus: MoveStatus.progressed,
      );
    } else {
      // opponent  is batting
      final updatedOpponent = currentState.opponent.copyWith(
        score: currentState.opponent.score + opponentMove,
        ballsFaced: currentState.opponent.ballsFaced + 1,
      );

      state = currentState.copyWith(
        opponent: updatedOpponent,
        message:
            '${currentState.mode == GameMode.practice ? 'Computer' : 'Opponent'} scored $opponentMove runs!',
        moveStatus: MoveStatus.progressed,
      );
    }

    // Check for chase completion in innings 2
    if (currentState.phase == GamePhase.innings2) {
      final firstInningsScore =
          currentState.player.isBatting
              ? currentState.opponent.score
              : currentState.player.score;

      final currentScore =
          currentState.player.isBatting
              ? currentState.player.score + playerMove
              : currentState.opponent.score + opponentMove;

      if (currentScore > firstInningsScore) {
        // Chase completed
        // Continue game after delay
        Timer(Duration(seconds: 2), () {
          _endGame();
        });
        return;
      }
    }

    // Continue game after delay
    Timer(Duration(seconds: 2), () {
      _checkInningsEnd();
    });
  }

  void _checkInningsEnd() {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;

    // Check if current batsman is out or has faced 6 balls
    bool inningsEnded = false;

    if (currentState.player.isBatting) {
      inningsEnded =
          currentState.player.isOut || currentState.player.ballsFaced >= 6;
    } else {
      inningsEnded =
          currentState.opponent.isOut || currentState.opponent.ballsFaced >= 6;
    }

    if (inningsEnded) {
      if (currentState.phase == GamePhase.innings1) {
        // start innings 2 countdown timer
        _startInningsCountdown(GamePhase.innings2);
      } else {
        // Game over
        _endGame();
      }
    } else {
      // Continue current innings
      _continueInnings();
    }
  }

  void _continueInnings() {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;

    // update state on gameroom
    if (currentState.mode == GameMode.online && currentState.roomId != null) {
      gameFirestoreService.updateGameRoom(
        id: currentState.roomId!,
        player: currentState.player,
        choice: 0,
      );
    }

    state = currentState.copyWith(
      message:
          currentState.player.isBatting
              ? 'Choose your next move!'
              : 'Stop the computer!',
      moveChoice: 0,
      opponentChoice: 0,
      moveStatus: MoveStatus.next,
    );

    _startMoveTimer();
  }

  void _endGame() {
    if (state is! GameStarted) return;

    final currentState = state as GameStarted;

    // Determine winner
    String resultMessage;
    PlayerType? winner;
    bool isTie = false;
    if (currentState.player.score > currentState.opponent.score) {
      resultMessage =
          'Congratulations! You won by ${currentState.player.score - currentState.opponent.score} runs!';
      winner = currentState.player.type;
    } else if (currentState.opponent.score > currentState.player.score) {
      resultMessage =
          '${currentState.opponent.name} wins by ${currentState.opponent.score - currentState.player.score} runs!';
      winner = currentState.opponent.type;
    } else {
      isTie = true;
      resultMessage = 'It\'s a tie! Great match!';
    }

    // update game result on gameroom
    if (currentState.mode == GameMode.online && currentState.roomId != null) {
      gameFirestoreService.updateGameRoom(
        id: currentState.roomId!,
        player: currentState.player,
        message: resultMessage,
        phase: GamePhase.result,
        result: GameResultType.valid,
        isTie: isTie,
        winner: winner,
        status: GameStatus.finished,
      );
    }

    state = GameResult(
      player: currentState.player,
      opponent: currentState.opponent,
      message: resultMessage,
      winner: winner,
    );
  }

  String _getScoreMessage(int score) {
    switch (score) {
      case 1:
        return 'Nice play! $score run';
      case 2:
      case 3:
        return 'Nice play! $score runs';
      case 4:
        return 'What a shot! $score runs';
      case 5:
        return 'Great shot! $score runs';
      case 6:
        return 'It\'s a six! Amazing!';
      default:
        return 'No runs scored';
    }
  }

  void resetGame() {
    _gameTimer?.cancel();
    _moveTimer?.cancel();
    _pausedMainTimer = 0;
    _pausedPhase = null;
    _pausedMoveStatus = null;
    state = GameInitial();
  }
}

// GameState
abstract class GameState extends Equatable {
  @override
  List<Object?> get props => [];
}

class GameInitial extends GameState {}

class GameStarted extends GameState {
  final GamePhase phase;
  final GamePlayer player;
  final GamePlayer opponent;
  final bool isBattingFirst;
  final String message;
  final int mainTimer;
  final int moveChoice;
  final int opponentChoice;
  final MoveStatus moveStatus;
  final int? target;
  final bool isPaused;
  final GameMode mode;
  final String? roomId;

  GameStarted({
    this.phase = GamePhase.toss,
    required this.player,
    required this.opponent,
    required this.isBattingFirst,
    this.message = '',
    this.mainTimer = 0,
    this.moveChoice = 0,
    this.opponentChoice = 0,
    this.target,
    required this.moveStatus,
    this.isPaused = false,
    required this.mode,
    this.roomId,
  });

  GameStarted copyWith({
    GamePhase? phase,
    GamePlayer? player,
    GamePlayer? opponent,
    bool? isBattingFirst,
    String? message,
    int? mainTimer,
    int? moveChoice,
    int? opponentChoice,
    MoveStatus? moveStatus,
    int? target,
    bool? isPaused,
    GameMode? mode,
    String? roomId,
  }) {
    return GameStarted(
      phase: phase ?? this.phase,
      player: player ?? this.player,
      opponent: opponent ?? this.opponent,
      isBattingFirst: isBattingFirst ?? this.isBattingFirst,
      message: message ?? this.message,
      mainTimer: mainTimer ?? this.mainTimer,
      moveChoice: moveChoice ?? this.moveChoice,
      opponentChoice: opponentChoice ?? this.opponentChoice,
      moveStatus: moveStatus ?? this.moveStatus,
      target: target ?? this.target,
      isPaused: isPaused ?? this.isPaused,
      mode: mode ?? this.mode,
      roomId: roomId ?? this.roomId,
    );
  }

  @override
  List<Object?> get props => [
    phase,
    player,
    opponent,
    isBattingFirst,
    message,
    mainTimer,
    moveChoice,
    opponentChoice,
    moveStatus,
    target,
    isPaused,
    mode,
    roomId,
  ];
}

class GameWaiting extends GameState {
  final GamePlayer player;
  final GamePlayer? opponent;
  final GameMode mode;
  final int mainTimer;
  final String message;
  final bool toss;
  final GameWaitingStatus status;
  final String? roomId;

  GameWaiting({
    required this.player,
    this.opponent,
    required this.mode,
    this.mainTimer = 0,
    this.message = '',
    required this.status,
    required this.toss,
    this.roomId,
  });

  GameWaiting copyWith({
    GamePlayer? player,
    GamePlayer? opponent,
    GameMode? mode,
    int? mainTimer,
    String? message,
    GameWaitingStatus? status,
    bool? toss,
    String? roomId,
  }) {
    return GameWaiting(
      player: player ?? this.player,
      opponent: opponent ?? this.opponent,
      mode: mode ?? this.mode,
      mainTimer: mainTimer ?? this.mainTimer,
      message: message ?? this.message,
      status: status ?? this.status,
      toss: toss ?? this.toss,
      roomId: roomId ?? this.roomId,
    );
  }

  @override
  List<Object?> get props => [
    player,
    opponent,
    mode,
    mainTimer,
    message,
    status,
    toss,
  ];
}

class GameResult extends GameState {
  final GamePlayer player;
  final GamePlayer opponent;
  final String message;
  final PlayerType? winner;
  final String? roomId;

  GameResult({
    required this.player,
    required this.opponent,
    required this.message,
    required this.winner,
    this.roomId,
  });
}

class GameError extends GameState {
  final String error;

  GameError(this.error);

  @override
  List<Object?> get props => [error];

  @override
  String toString() => 'GameError: $error';
}

enum MoveStatus { next, wait, progress, progressed, start, end, paused }

enum GameMode { online, practice }

enum GameWaitingStatus { wait, matched, timedOut, started }
