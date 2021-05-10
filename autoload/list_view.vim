function list_view#set(query, list) abort
	let buf_contents = ["> [" . len(a:list) . "] " . a:query] + a:list
	silent call deletebufline(g:jira_list_buffer, 1, "$")
	call setbufline(g:jira_list_buffer, 1, buf_contents)
endfunction

function s:handle_cursor_moved() abort
	let pos = getpos(".")
	if pos[1] == 1
		let idx = stridx(getline("."), "]") + 3
		if pos[2] < idx
			call cursor(1, idx)
		endif
		let b:cached_line = 1
		return
	endif

	call cursor(pos[1], 1)
	if pos[1] == get(b:, "cached_line", -1)
		return
	endif
	let b:cached_line = pos[1]

	let key = utils#get_key()
	if empty(key)
		return
	endif

	call issue_view#load(key, {})
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

	call issue_view#load(utils#get_key(), {"reload": 1})
endfunction

" TODO This is still in progress
function s:create_issue() abort
	function! s:format_create_meta(data, project_key) abort
		let issue_types = a:data.projects[0].issuetypes
		let issue_type_choice = inputlist(
			\ ["Choose issue type:"] +
			\ map(copy(issue_types), {k,v -> (k + 1) . ". " . v.name}),
		\ )

		let issue_type = issue_types[issue_type_choice - 1]
		let buf_contents = ["# Create issue for " . a:project_key]
		for [name, field] in items(issue_type.fields)
			let required = field.required ? "*" : ""
			call add(buf_contents, printf("-> %s%s [%s]:",
				\ field.name,
				\ required,
				\ field.schema.type,
			\ ))

			if field.hasDefaultValue && has_key(field, "defaultValue")
				if field.name == "Priority"
					call add(buf_contents, json_encode({
						\ "id": field.defaultValue.id,
						\ "name": field.defaultValue.name
					\ }))
				else
					call add(buf_contents, json_encode(field.defaultValue))
				endif
			endif

			if field.name == "Reporter"
				call add(buf_contents, json_encode({"id": utils#get_account_id()}))

			elseif field.name == "Project"
				call add(buf_contents, a:project_key)

			elseif field.name == "Project"
				call add(buf_contents, a:project_key)

			elseif field.name == "Issue Type"
				call add(buf_contents, json_encode({
					\ "id": issue_type.id,
					\ "name": issue_type.name
				\ }))
			endif
			
			call add(buf_contents, "")
		endfor
		redraw
		echo join(buf_contents, "\n")
	endfunction

	function! s:choose_board(data) abort closure
		let orig_data = a:data
		call sort(orig_data.values, {i1, i2 -> i1.name - i2.name})

		let counter = 1
		let board_choices = ["Choose board:"]
		for board in orig_data.values
			if ! has_key(board.location, "projectName")
				continue
			endif
			call add(board_choices, printf("%2i. %s - %s",
				\ counter,
				\ board.name,
				\ board.location.name,
			\ ))
			let counter += 1
		endfor

		let choice = inputlist(board_choices) - 1
		if choice < 0 || choice > len(orig_data.values)
			return
		endif

		let project_key = orig_data.values[choice].location.projectKey

		call api#get_create_metadata(
			\ {d -> s:format_create_meta(d, project_key)},
			\ project_key,
		\ )
	endfunction

	call api#get_boards({d -> s:choose_board(d)})
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
	let issues = ["1\t2\t3\t4\t5\t6"]
	for issue in a:list
		let status = issue.fields.status.name
		let status = utils#clamp(get(utils#get_status_abbreviations(), status, status), 17)

		let issue_type = issue.fields.issuetype.name
		let issue_type = get(utils#get_issue_type_abbreviations(), issue_type, issue_type)

		let most_recent_sprint = ""
		let sprints = issue.fields.customfield_10005
		if type(sprints) == v:t_list && len(sprints) > 0
			let sorted_sprints = s:sort_sprint_list(sprints)
			let most_recent_sprint = sorted_sprints[0].shortname
		endif

		let assignee = ""
		if type(issue.fields.assignee) == v:t_dict
			let assignee = utils#get_initials(issue.fields.assignee.displayName)
		endif

		let fmt_issue = [
			\ " " . issue.key,
			\ status,
			\ issue_type,
			\ most_recent_sprint,
			\ assignee,
			\ issue.fields.summary
		\ ]
		call add(issues, join(fmt_issue, "\t"))
	endfor

	return systemlist([
		\ "column",
		\ "--table",
		\ "--separator=\t",
		\ "--output-separator= "
	\ ], issues)
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

	syntax case ignore
	syntax keyword JQLKeywords AND IN OR NOT EMPTY ORDER BY WAS CHANGED contained
	syntax keyword JQLFields contained
		\ assignee comment created creator description id issueKey key priority
		\ project rank reporter sprint status summary text type updated watcher
		\ watchers
	syntax case match

	syntax keyword JQLFunctions openSprints futureSprints currentUser contained
	syntax match JQLOperators '=\|!=\|>\|>=\|<\|<=\|\~\|!\~' contained
	syntax match JQLString '".[^"]\+"' contained
	syntax match JQLString +'.[^']\+'+ contained

	syntax cluster JiraQueryElements contains=JQLKeywords,JQLFunctions,JQLOperators,JQLString,JQLFields

	nnoremap <buffer> <CR> :call <SID>handle_enter()<CR>
	inoremap <buffer> <CR> <Esc>:call <SID>handle_enter()<CR>
	nnoremap <buffer> q :qa!<CR>
	nnoremap <buffer> <silent> <tab> :call utils#goto_buffer(g:jira_issue_buffer)<CR>
	nnoremap <buffer> R :call issue_view#load(utils#get_key(), {"reload": 1})<CR>
	nnoremap <buffer> zv :call issue_view#toggle()<CR>
	nnoremap <buffer> gx :call system(["xdg-open", utils#get_issue_url(utils#get_key())])<CR>

	function! s:complete_queries(A, L, P) abort
		return join(keys(utils#get_saved_queries()), "\n")
	endfunction
	command! -buffer -nargs=?
		\ -complete=custom,<SID>complete_queries
		\ JiraQuery :call Jira(get(utils#get_saved_queries(), <q-args>, "mysprint"))

	command! -buffer -nargs=0 JiraCreateIssue :call s:create_issue()
	command! -buffer -nargs=0 JiraToggleIssueView :call issue_view#toggle()

	augroup jira
		autocmd!
		autocmd CursorMoved <buffer> call <SID>handle_cursor_moved()
		autocmd InsertEnter <buffer> call <SID>handle_insert_enter()
	augroup END
endfunction

function list_view#setup_highlighting(markers) abort
	let c1 = matchend(a:markers, '1\s\+')
	let c2 = matchend(a:markers, '2\s\+', c1)
	let c3 = matchend(a:markers, '3\s\+', c2)
	let c4 = matchend(a:markers, '4\s\+', c3)
	let c5 = matchend(a:markers, '5\s\+', c4)

	exe 'syntax match JiraKey "\%<'.c1.'c\<\u\+-\d\+\>"'

	exe 'syntax match JiraStatusBlocked "\%>'.c1.'c\<B\>\%<'.(c2+1).'c"'
	exe 'syntax match JiraStatusDone "\%>'.c1.'c\<D\>\%<'.(c2+1).'c"'
	exe 'syntax match JiraStatusInProgress "\%>'.c1.'c\<P\>\%<'.(c2+1).'c"'
	exe 'syntax match JiraStatusToDo "\%>'.c1.'c\<T\>\%<'.(c2+1).'c"'

	exe 'syntax match JiraTypeBug "\%>'.c2.'c\<B\>\%<'.(c3+1).'c"'
	exe 'syntax match JiraTypeEpic "\%>'.c2.'c\<E\>\%<'.(c3+1).'c"'
	exe 'syntax match JiraTypeStory "\%>'.c2.'c\<S\>\%<'.(c3+1).'c"'
	exe 'syntax match JiraTypeTask "\%>'.c2.'c\<T\>\%<'.(c3+1).'c"'

	let inits = utils#get_initials(utils#get_display_name())
	exe 'syntax match JiraAssigneeMe "\%>'.c4.'c\<'.inits.'\>\%<'.(c5+1).'c"'
	exe 'syntax match JiraAssigneeNone "\%>'.c4.'c\('.inits.'\)\@!\<\u\u\>\%<'.(c5+1).'c"'
endfunction
