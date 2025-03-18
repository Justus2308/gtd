#define PROC_COUNT 50

#define UNREFERENCED 0
#define MAX_REF_COUNT (2147483647 - 3)
#define UNLOADING (MAX_REF_COUNT + 1)
#define UNLOADED (UNLOADING + 1)
#define LOADING (UNLOADED + 1)

#define CMPXCHG_WEAK(var, exp, new, res)     \
	atomic {                                 \
		if                                   \
		:: (var == exp) ->                   \
			if                               \
			:: { var = new; res = 1 }        \
			:: { res = 0 }                   \
			fi                               \
		:: else -> res = 0                   \
		fi                                   \
	}

#define INCR(val) val = (val + 1)
#define DECR(val) val = (val - 1)

int state = UNLOADED;

#define LOAD_COMPLETED 0
#define UNLOAD_COMPLETED 1
#define LOAD_SKIPPED 2
#define UNLOAD_SKIPPED 3
chan result = [2*PROC_COUNT] of { byte };

proctype load() {
	do
	:: (true) ->
		if
		:: (state == UNLOADED) ->
			bool res;
			CMPXCHG_WEAK(state, UNLOADED, LOADING, res)
			if
			:: (res == 0) -> skip
			:: (res == 1) -> goto cont
			fi
		:: (state == UNLOADING) -> skip
		:: else -> goto fail
		fi
	od

	cont:
		atomic {
			assert(state == LOADING);
			state = UNREFERENCED;

			result!LOAD_COMPLETED
		}
		goto done
		
	fail:
		result!LOAD_SKIPPED
	done:
		skip
}
proctype unload() {
	do
	:: (true) ->
		if
		:: (state == UNREFERENCED) ->
			bool res;
			CMPXCHG_WEAK(state, UNREFERENCED, UNLOADING, res)
			if
			:: (res == 0) -> skip
			:: (res == 1) -> goto cont
			fi
		:: (state == LOADING) -> skip
		:: else -> goto fail
		fi
	od

	cont:
		atomic {
			assert(state == UNLOADING);
			state = UNLOADED;

			result!UNLOAD_COMPLETED
		}
		goto done
	fail:
		result!UNLOAD_SKIPPED
	done:
		skip
}

proctype addReference() {
	do
	:: (true) ->
		if
		:: (state == UNLOADING || state == UNLOADED) -> goto done
		:: (state == LOADING) -> skip
		:: (state == MAX_REF_COUNT) -> goto done
		:: else ->
			int state_ = state;
			bool res;
			CMPXCHG_WEAK(state, state_, (state + 1), res)
			if
			:: (res == 0) -> skip
			:: (res == 1) -> goto done
			fi
		fi
	od

	done:
		skip
}
proctype removeReference() {
	do
	:: (true) ->
		if
		:: (state == UNREFERENCED
			|| state == UNLOADING
			|| state == UNLOADED
			|| state == LOADING) -> goto done
		:: else ->
			int state_ = state;
			bool res;
			CMPXCHG_WEAK(state, state_, (state - 1), res)
			if
			:: (res == 0) -> skip
			:: (res == 1) -> goto done
			fi
		fi
	od

	done:
		skip
}

init {
	int count = 0;
	do
	:: (count < PROC_COUNT) ->
		run load();
		run addReference();
		run removeReference();
		run unload();
		INCR(count)
	:: else -> break
	od

	count = 0;
	int load_completed_count = 0;
	int unload_completed_count = 0;
	int load_skipped_count = 0;
	int unload_skipped_count = 0;
	byte res;
	do
	:: (count < (2*PROC_COUNT)) ->
		result?res
		if
		:: (res == LOAD_COMPLETED) -> INCR(load_completed_count)
		:: (res == UNLOAD_COMPLETED) -> INCR(unload_completed_count)
		:: (res == LOAD_SKIPPED) -> INCR(load_skipped_count)
		:: (res == UNLOAD_SKIPPED) -> INCR(unload_skipped_count)
		fi
		INCR(count)
	:: else -> break
	od

	printf("Number of completed loads: %d\n", load_completed_count);
	printf("Number of completed unloads: %d\n", unload_completed_count);
	printf("Number of skipped loads: %d\n", load_skipped_count);
	printf("Number of skipped unloads: %d\n", unload_skipped_count);

	atomic {
		int diff = (load_completed_count - unload_completed_count);
		assert(diff <= 1 && diff >= -1)
	}
}
