function list_view#the() abort
	return bufadd("jira-list-buffer")
endfunction

function list_view#set(query, data) abort
	if has_key(a:data, "errorMessages") || has_key(a:data, "warningMessages")
		let fmt_list = get(a:data, "errorMessages", []) + get(a:data, "warningMessages", [])
	    let len = 0
	elseif has_key(a:data, "issues")
		let len = a:data.total
		let [header; fmt_list] = list_view#format(a:data.issues)
		call list_view#setup_highlighting(header)

		if a:data.total > a:data.startAt + a:data.maxResults
			let next_page = printf(
				\ "> Next page (currently displaying %i to %i of %i)",
				\ a:data.startAt + 1,
				\ a:data.startAt + a:data.maxResults,
				\ a:data.total
			\ )
			call add(fmt_list, next_page)
		endif
	else
		echoerr "Could not understand response"
	endif

	let buf_contents = ["> [" . len . "] " . a:query] + fmt_list
	let list_buf = list_view#the()
	silent call deletebufline(list_buf, 1, "$")
	call setbufline(list_buf, 1, buf_contents)
endfunction

function s:handle_cursor_moved() abort
	let pos = getpos(".")
	if pos[1] == 1
		let idx = stridx(getline("."), "]") + 3
		if pos[2] < idx
			call cursor(1, idx)
		endif
	else
		call cursor(pos[1], 1)
	endif

	if pos[1] == b:cached_line
		return
	endif
	let b:cached_line = pos[1]

	if pos[1] == 1
		call issue_view#load_previous_window("summary")
		return
	endif

	let key = utils#get_key()
	if empty(key)
		return
	endif

	call issue_view#load_previous_window(key)
endfunction

function s:handle_insert_enter() abort
	let pos = getpos(".")
	let start_of_query = match(getline(1), " ", 3) + 2
	if pos[1] == 1 && pos[2] >= start_of_query
		return
	endif

	call cursor(1, 9999)
	let v:char = "1"
endfunction

function s:handle_enter() abort
	let line = getline(".")
	if line(".") == 1
		let query = substitute(line, '^> \[\d\+\] ', "", "")
		call Jira(query)
		return
	endif

	if getline(".") =~# "^> Next page"
		let query = substitute(getline(1), '^> \[\d\+\] ', "", "")
		let start_at = g:jira_query_data.startAt + g:jira_query_data.maxResults
		call Jira(query, {"start_at": start_at})
		return
	endif

	if len(getwininfo()) < 2
		call issue_view#open(utils#get_key())
	else
		call issue_view#reload(utils#get_key())
	endif
endfunction

function s:cache_summary() abort
	let cache_glob = utils#cache_file("*")
	let totals = {"count": 0, "size": 0, "max": {"size": 0, "fname": ""}}
	for f in glob(cache_glob, 1, 1)
		let totals.count += 1
		let size = getfsize(f)
		let totals.size += size
		if size > totals.max.size
			let totals.max.size = size
			let totals.max.fname = f
		endif
	endfor

	echo printf(join([
		\ "Cache Summary:",
		\ "  Count: " . totals.count,
		\ "  Size: " . utils#human_bytes(totals.size),
		\ printf("  Largest: %s (%s)",
			\ fnamemodify(totals.max.fname, ":~"),
			\ utils#human_bytes(totals.max.size)
		\ ),
	\ ], "\n"))
endfunction

" TODO This is still in progress
function s:create_issue() abort
	function! s:format_create_meta(issue_type, project_key) abort
		let buf_contents = ["# Create issue for " . a:project_key]
		for [name, field] in items(a:issue_type.fields)
			let required = field.required ? "*" : ""
			call add(buf_contents, printf("-> %s%s [%s]:",
				\ field.name,
				\ required,
				\ field.schema.type,
			\ ))

			if field.hasDefaultValue && has_key(field, "defaultValue")
				let default_value = field.defaultValue
				if field.name == "Priority"
					let default_value = {
						\ "id": field.defaultValue.id,
						\ "name": field.defaultValue.name
					\ }
				endif
				call add(buf_contents, "Default: " . json_encode(default_value))
			endif

			if field.name == "Reporter"
				call add(buf_contents, json_encode({"id": utils#get_account_id()}))

			elseif field.name == "Project"
				call add(buf_contents, a:project_key)

			elseif field.name == "Project"
				call add(buf_contents, a:project_key)

			elseif field.name == "Issue Type"
				call add(buf_contents, json_encode({
					\ "id": a:issue_type.id,
					\ "name": a:issue_type.name
				\ }))
			endif

			call add(buf_contents, "")
		endfor
		redraw
		echo join(buf_contents, "\n")
	endfunction

	call choose#board({board -> api#get_create_metadata(
		\ {create_meta -> choose#issue_type(
			\ {create_meta_type -> s:format_create_meta(create_meta_type, board.location.projectKey)},
			\ create_meta.projects[0].issuetypes
		\ )},
		\ board.location.projectKey,
	\ )})
endfunction

function s:sort_sprint_list(sprints) abort
	let sprints = []
	for sprint in copy(a:sprints)
		let sprint.shortname = utils#sprint_short_name(sprint.name)
		call add(sprints, sprint)
	endfor
	return sort(sprints, {i1, i2 -> i2.id - i1.id})
endfunction

function list_view#format(list) abort
	let issues = []
	for issue in a:list
		let status = issue.fields.status.name
		let status = utils#clamp(get(utils#get_status_abbreviations(), status, status), 17)

		let issue_type = issue.fields.issuetype.name
		let issue_type = utils#clamp(get(utils#get_issue_type_abbreviations(), issue_type, issue_type), 10)

		let sprints = issue.fields.customfield_10005
		let most_recent_sprint = type(sprints) == v:t_list && len(sprints) > 0
			\ ? s:sort_sprint_list(sprints)[0].shortname
			\ : ""

		let assignee = type(issue.fields.assignee) == v:t_dict
			\ ? utils#get_initials(issue.fields.assignee.displayName)
			\ : ""

		let fmt_issue = [
			\ " " . issue.key,
			\ status,
			\ issue_type,
			\ assignee,
			\ issue.fields.summary
		\ ]

		" Remove tab characters that mess with formatting
		call map(fmt_issue, {k,v -> substitute(v, "\t", " ", "g")})
		call add(issues, fmt_issue)
	endfor

	if len(issues) == 0
		return [""]
	endif

	let col_markers = range(len(issues[0]))
	call insert(issues, col_markers)

	return utils#tab_align(issues)
endfunction

function s:format_boards(boards) abort
	let headers = [["KEY", "NAME", "DISPLAY NAME", "TYPE"]]
	let fmt_boards = []
	for board in a:boards.values
		let is_project = has_key(board.location, "projectId")
		call add(fmt_boards, [
			\ is_project ? board.location.projectKey : "-",
			\ board.name,
			\ board.location.displayName,
			\ board.type,
		\ ])
	endfor

	echo join(utils#tab_align(headers + sort(fmt_boards)), "\n")
endfunction

function list_view#setup() abort

	setlocal buftype=nofile
	setlocal colorcolumn=0
	setlocal cursorline
	setlocal foldmethod=manual
	setlocal nonumber
	setlocal noswapfile
	setlocal nowrap
	setlocal sidescrolloff=10
	setlocal textwidth=0
	setlocal virtualedit=onemore

	syntax clear
	call utils#setup_highlight_groups()

	syntax match JiraPrompt '\%^>'
	syntax match JiraPromptCount '\(\%^> \)\@2<=\[\d\+\]'
	syntax match JiraQuery '\(\%^> \[\d\+\] \)\@10<=.*' contains=@JiraQueryElements

	syntax match JiraPrompt '^>\( Next page \)\@='
	syntax match JiraPromptCount '\(^>\)\@2<= Next page .*'

	syntax case ignore
	syntax keyword JQLKeywords AND IN OR NOT EMPTY ORDER BY WAS CHANGED contained
	syntax keyword JQLFields contained
		\ assignee comment created creator description id issueKey key priority
		\ project rank reporter sprint status statusCategory summary text type
		\ updated watcher watchers
	syntax case match

	syntax keyword JQLFunctions openSprints futureSprints currentUser contained
	syntax match JQLOperators '=\|!=\|>\|>=\|<\|<=\|\~\|!\~' contained
	syntax match JQLString '".[^"]\+"' contained
	syntax match JQLString +'.[^']\+'+ contained

	syntax cluster JiraQueryElements contains=JQLKeywords,JQLFunctions,JQLOperators,JQLString,JQLFields

	nnoremap <buffer> <silent> <CR> :call <SID>handle_enter()<CR>
	inoremap <buffer> <silent> <CR> <Esc>:call <SID>handle_enter()<CR>
	nnoremap <buffer> <silent> q :qa!<CR>

	function! s:complete_queries(A, L, P) abort
		return join(keys(utils#get_saved_queries()), "\n")
	endfunction
	command! -buffer -nargs=?
		\ -complete=custom,<SID>complete_queries
		\ JiraQuery :call Jira(get(utils#get_saved_queries(), <q-args>, "mysprint"))

	command! -buffer -nargs=0 JiraCreateIssue :call s:create_issue()
	command! -buffer -nargs=0 JiraCacheSummary :call s:cache_summary()
	command! -buffer -nargs=0 JiraListBoards :call api#get_boards({boards -> s:format_boards(boards)})

	augroup jira
		autocmd!
		autocmd CursorMoved <buffer> ++nested call <SID>handle_cursor_moved()
		autocmd InsertEnter <buffer> call <SID>handle_insert_enter()
	augroup END

	let b:cached_line = 1
endfunction

function list_view#setup_highlighting(markers) abort
	if empty(a:markers)
		return
	endif

	let c0 = matchend(a:markers, '0\s\+')
	let c1 = matchend(a:markers, '1\s\+', c0)
	let c2 = matchend(a:markers, '2\s\+', c1)
	let c3 = matchend(a:markers, '3\s\+', c2)
	let c4 = matchend(a:markers, '4$', c3)

	exe 'syntax match JiraKey "\%<'.c0.'c\<\u\+-\d\+\>"'

	exe 'syntax match JiraStatusBlocked "\%>'.c0.'v\<B\>\%<'.(c1+1).'v"'
	exe 'syntax match JiraStatusDone "\%>'.c0.'v\<D\>\%<'.(c1+1).'v"'
	exe 'syntax match JiraStatusInProgress "\%>'.c0.'v\<P\>\%<'.(c1+1).'v"'
	exe 'syntax match JiraStatusToDo "\%>'.c0.'v\<T\>\%<'.(c1+1).'v"'

	exe 'syntax match JiraTypeBug "\%>'.c1.'v\<B\>\%<'.(c2+1).'v"'
	exe 'syntax match JiraTypeEpic "\%>'.c1.'v\<E\>\%<'.(c2+1).'v"'
	exe 'syntax match JiraTypeStory "\%>'.c1.'v\<S\>\%<'.(c2+1).'v"'
	exe 'syntax match JiraTypeTask "\%>'.c1.'v\<T\>\%<'.(c2+1).'v"'

	let inits = utils#get_initials(utils#get_display_name())
	exe 'syntax match JiraAssigneeMe "\%>'.c2.'v\<'.inits.'\>\%<'.(c3+1).'v"'
	exe 'syntax match JiraAssigneeNone "\%>'.c2.'v\('.inits.'\)\@!\<\u\u\>\%<'.(c4+1).'v"'
endfunction
