// TODO: find a way to handle 'null pointers' (NULL_INDEX)

#define NODE_SET(dest, src)                     \
	dest.is_deleted = src.is_deleted;           \
	dest.next_index = src.next_index;

#define NODE_EQL(a, b)                          \
	(a.is_deleted == b.is_deleted &&            \
		a.next_index == b.next_index)

#define CMPXCHG_WEAK(var, exp, new, res)        \
	atomic {                                    \
		if                                      \
		:: (NODE_EQL(var, exp)) ->              \
			if                                  \
			:: { NODE_SET(var, new); res = 1 }  \
			:: { res = 0 }                      \
			fi                                  \
		:: else -> res = 0                      \
		fi                                      \
	}

#define INCR(val) val = (val + 1)
#define DECR(val) val = (val - 1)

#define NULL_INDEX -1
#define MAX_CREATED_COUNT 120

typedef Node {
	bool is_deleted;
	int next_index;
};

int alloc_index;
Node nodes[MAX_CREATED_COUNT];
chan created = [MAX_CREATED_COUNT] of { int };
int free_list_index;

init {
	alloc_index = 0;
	free_list_index = NULL_INDEX;

	atomic {
		int count = 0;
		do
		:: (count < MAX_CREATED_COUNT) ->
			run create();
			run destroy();
			INCR(count)
		:: else -> break
		od
	}
	assert(len(created) == 0);
}

proctype create() {
	bool res;

	Node head;
	int head_index = free_list_index;
	do
	:: (true) ->
		atomic {
			if
			:: (head_index == NULL_INDEX) ->
				int index = alloc_index;
				INCR(alloc_index);
				created!index
				goto done;
			else -> NODE_SET(head, nodes[head_index]);
			fi
		}


		do
		:: (head.is_deleted == 0) ->
			Node deleted_head;
			NODE_SET(deleted_head, head);
			deleted_head.is_deleted = 1;
			CMPXCHG_WEAK(nodes[free_list_index], head, deleted_head, res);
			if
			:: (res == 0) -> atomic {
				head_index = free_list_index;
				NODE_SET(head, nodes[head_index]);
			};
			:: (res == 1) -> NODE_SET(head, deleted_head);
			fi
		od

		CMPXCHG_WEAK(nodes[free_list_index], head, nodes[head.next_index], res);
		if
		:: (res == 0) -> atomic {
			head_index = free_list_index;
			NODE_SET(head, nodes[head_index]);
		};
		:: (res == 1) ->
			created!head_index;
			goto done;
		fi
	od

	done:
		skip
}

proctype destroy() {
	bool res;

	int index;
	created?index;

	Node node;
	node.is_deleted = 0;

	Node head;
	int head_index = free_list_index;
	do
	:: (true) ->
		do
		:: (head_index == NULL_INDEX) -> break;
		:: (head_index != NULL_INDEX) -> atomic {
			head_index = free_list_index;
			NODE_SET(head, nodes[head_index]);
			if
			:: (head.is_deleted == 0) -> break;
			fi
		}
		od

		node.next_index = head_index;

		CMPXCHG_WEAK(nodes[free_list_index], head, node, res);
		if
		:: (res == 0) -> atomic {
			head_index = free_list_index;
			NODE_SET(head, nodes[head_index]);
		}; 
		:: (res == 1) -> goto done;
		fi
	od

	done:
		skip
}
