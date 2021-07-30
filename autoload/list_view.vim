function list_view#the() abort
	return bufadd("jira-list")
endfunction

function list_view#set(query, data) abort
	let len = 0

	if type(a:data) == v:t_dict
		if utils#has_keys(a:data, ["issues", "maxResults", "startAt", "total"])
			let len = a:data.total
			let fmt_list = list_view#format(a:data.issues)
			call list_view#setup_highlighting(fmt_list[0])
			let fmt_list = fmt_list[1:]

			if a:data.total > a:data.startAt + a:data.maxResults
				let next_page = printf(
					\ "> Next page (currently displaying %i to %i of %i)",
					\ a:data.startAt + 1,
					\ a:data.startAt + a:data.maxResults,
					\ a:data.total
				\ )
				call add(fmt_list, next_page)
			endif

		elseif has_key(a:data, "errorMessages")
			let fmt_list = a:data.errorMessages

		elseif has_key(a:data, "warningMessages")
			let fmt_list = a:data.warningMessages

		else
			let fmt_list = ["Could not understand response", string(a:data)]
		endif
	elseif type(a:data) == v:t_list
		let fmt_list = map(a:data, {k,v -> type(v) == v:t_string ? v : string(v)})
	else
		let fmt_list = [string(a:data)]
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
		let buf_contents = [
			\ "Reporter:   " . utils#get_display_name(),
			\ "Project:    " . a:project_key,
			\ "Issue type: " . a:issue_type.name,
			\ "",
			\ "Summary: ",
			\ "",
			\ "Description:",
			\ "",
		\ ]
		call writefile(buf_contents, utils#cache_file("create.txt"))

		if len(getwininfo()) < 2
			call issue_view#open("create")
		else
			wincmd p
			call issue_view#load("create")
		endif
	endfunction

	call choose#project({project -> api#get_create_metadata(
		\ {create_meta -> len(create_meta.projects) == 0
			\ ? utils#echo("You don't have permission to create issues in that project")
			\ : choose#issue_type(
				\ {create_meta_type -> s:format_create_meta(create_meta_type, project.key)},
				\ create_meta.projects[0].issuetypes
			\ )},
		\ project.key,
	\ )})
endfunction

function list_view#format(list) abort
	let issues = []
	for issue in a:list
		let status = issue.fields.status.name
		let status = utils#clamp(get(utils#get_status_abbreviations(), status, status), 17)

		let issue_type = issue.fields.issuetype.name
		let issue_type = utils#clamp(get(utils#get_issue_type_abbreviations(), issue_type, issue_type), 10)

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
	if len(get(a:boards, "values", [])) == 0
		return
	endif
	let headers = [["KEY", "NAME", "DISPLAY NAME", "TYPE"]]
	let fmt_boards = map(a:boards.values, {k,v -> [
		\ has_key(v.location, "projectId") ? v.location.projectKey : "-",
		\ v.name,
		\ v.location.displayName,
		\ v.type
	\ ]})

	echo join(utils#tab_align(headers + sort(fmt_boards)), "\n")
endfunction

function s:format_projects(projects) abort
	if len(get(a:projects, "values", [])) == 0
		return
	endif
	let headers = [["KEY", "NAME", "LEAD", "STYLE", "TYPE"]]
	let fmt_projects = sort(map(a:projects.values,
		\ {k,v -> [v.key, v.name, v.lead.displayName, v.style, v.projectTypeKey]}
	\ ))

	echo join(utils#tab_align(headers + fmt_projects), "\n")
endfunction

function s:format_versions(versions) abort
	if len(get(a:versions, "values", [])) == 0
		return
	endif
	let headers = [["NAME", "RELEASED", "START DATE", "RELEASE DATE", "ARCHIVED", "DESCRIPTION"]]
	let fmt_versions = map(a:versions, {k,v -> [
		\ v.name,
		\ v.released ? "yes" : "no",
		\ get(v, "startDate", ""),
		\ get(v, "releaseDate", ""),
		\ v.archived ? "yes" : "no",
		\ get(v, "description", "")
	\ ]})

	echo join(utils#tab_align(headers + fmt_versions), "\n")
endfunction

function s:list_versions(project) abort
	let List_versions_aux = {project -> api#get_versions(
		\ {versions -> s:format_versions(versions)},
		\ project
	\ )}
	if empty(trim(a:project))
		call choose#project({project -> List_versions_aux(project.key)})
	else
		call List_versions_aux(a:project)
	endif
endfunction

function s:format_components(components) abort
	if len(a:components) == 0
		return
	endif
	let headers = [["COMPONENT", "DESCRIPTION"]]
	let fmt_components = map(a:components, {k,v -> [v.name, get(v, "description", "")]})

	echo join(utils#tab_align(headers + fmt_components), "\n")
endfunction

function s:list_components(project) abort
	let List_components_aux = {project -> api#get_components({components -> s:format_components(components)}, project)}
	if empty(trim(a:project))
		call choose#project({project -> List_components_aux(project.key)})
	else
		call List_components_aux(a:project)
	endif
endfunction

function s:show_current_user() abort
	function! s:show_current_user_aux(user) abort
		let items = []
		for [key,value] in sort(items(a:user), {a,b -> a[0] - b[0]})
			if index(["avatarUrls", "expand", "self"], key) >= 0
				continue
			endif

			if key == "applicationRoles" || key == "groups"
				let value = map(value.items, {k,v -> v.name})
			endif

			let value = type(value) == v:t_bool ? (value ? 'yes' : 'no') : value
			call add(items, [key . ":", value])
		endfor
		echo join(utils#tab_align(items), "\n")
	endfunction
	call api#get_myself({myself -> s:show_current_user_aux(myself)})
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
		\ affectedVersion assignee attachments comment component created
		\ creator description due filter fixVersion id issueKey key labels
		\ priority project rank reporter resolved sprint status statusCategory
		\ summary text type updated voter watcher watchers
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
	command! -buffer -nargs=0 JiraListProjects :call api#get_projects({projects -> s:format_projects(projects)})
	command! -buffer -nargs=? JiraListVersions :call s:list_versions(<q-args>)
	command! -buffer -nargs=? JiraListComponents :call s:list_components(<q-args>)
	command! -buffer -nargs=0 JiraCurrentUser :call s:show_current_user()

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
