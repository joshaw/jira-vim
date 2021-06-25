function choose#generic(callback, prompt, data, f_filter, f_sort, f_format) abort
	if len(a:data) == 0
		echo "None to choose from"
		return
	endif

	let data = copy(a:data)

	if type(a:f_filter) == v:t_func
		call filter(data, a:f_filter)
	endif

	if type(a:f_sort) == v:t_func
		call sort(data, a:f_sort)
	endif

	let data_list = map(copy(data), {k,v -> printf("%2i. %s", k+1, a:f_format(v))})
	redraw
	let choice = inputlist([a:prompt . ":"] + data_list)
	if choice <= 0 || choice > len(data)
		return
	endif
	let datum = data[choice - 1]
	call call(a:callback, [datum])
endfunction

function choose#comment(callback, comments) abort
	call choose#generic(
		\ a:callback,
		\ "Choose comment",
		\ reverse(a:comments),
		\ 0,
		\ 0,
		\ {v -> utils#clamp(substitute(v.body, '\n\+', " ", "g"), &columns - 5)},
	\ )
endfunction

function choose#board(callback) abort
	call api#get_boards({boards -> choose#generic(
		\ a:callback,
		\ "Choose board",
		\ boards.values,
		\ 0,
		\ {a,b -> a.name - b.name},
		\ {v -> v.name . " - " . v.location.displayName},
	\ )})
endfunction

function choose#sprint(callback, board_id) abort
	call api#get_sprints({sprints -> choose#generic(
		\ a:callback,
		\ "Choose sprint",
		\ sprints.values,
		\ 0,
		\ {a,b -> a.id - b.id},
		\ {v -> printf("%s (%s)", v.name, v.state)},
	\ )}, a:board_id)
endfunction

function choose#epic(callback, board_id) abort
	call api#get_epics({epics -> choose#generic(
		\ a:callback,
		\ "Choose epic",
		\ epics.values,
		\ {k,v -> !v.done},
		\ {a,b -> a.id - b.id},
		\ {v -> v.key . " " . v.name},
	\ )}, a:board_id)
endfunction

function choose#link_type(callback) abort
	function! s:_choose_link_type(data) abort closure
		let links = []
		for link in a:data
			call add(links, [link.id, link.inward, "inward", link.name])
			call add(links, [link.id, link.outward, "outward", link.name])
		endfor

		call choose#generic(
			\ a:callback, "Choose link type", links, 0, 0, {v -> v[1]},
		\ )
	endfunction

	call api#get_link_types({types -> s:_choose_link_type(types.issueLinkTypes)})
endfunction

function choose#issue_type(callback, types) abort
	call choose#generic(
		\ a:callback, "Choose new issue type", a:types, 0, 0, {v -> v.name},
	\ )
endfunction

function choose#transition(callback, transitions) abort
	call choose#generic(
		\ a:callback, "Transition to", a:transitions, 0, 0, {v -> v.name},
	\ )
endfunction
