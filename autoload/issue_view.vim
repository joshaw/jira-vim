let s:transition_states = [
	\ {"name": "To Do", "id": 11},
	\ {"name": "In Progress", "id": 21},
	\ {"name": "Blocked", "id": 41},
	\ {"name": "Done", "id": 31},
\ ]

function s:wrap(str) abort
	return systemlist("fmt -s", a:str)
endfunction

function s:date(str) abort
	let date_ts = str2nr(systemlist(["date", "--date", a:str, "+%s"])[0])
	let now = localtime()

	let secs = now - date_ts
	if secs < 60 | return printf("%.0f seconds ago", secs) | endif

	let mins = secs / 60
	if mins < 91 | return printf("%.0f minutes ago", mins) | endif

	let hours = mins / 60
	if hours < 35 | return printf("%.0f hours ago", hours) | endif

	let days = hours / 24
	if days < 21 | return printf("%.0f days ago", days) | endif

	return strftime("%Y-%m-%d %H:%M", date_ts)
endfunction

function s:capitalise(str) abort
	return toupper(a:str[0]) . a:str[1:]
endfunction

function s:format_issue(issue, opts) abort
	if ! utils#issue_is_valid(a:issue)
		if has_key(a:issue, "errorMessages")
			return ["Error:"] + a:issue.errorMessages
		endif
		return [json_encode(a:issue)]
	endif

	let watching = ""
	if has_key(a:issue.fields, "watches")
		let watching = printf(" (w%s/%i)",
			\ a:issue.fields.watches.isWatching ? "+" : "-",
			\ a:issue.fields.watches.watchCount
		\ )
	endif

	let weblink = printf("https://exonar.atlassian.net/browse/%s (%s)%s",
		\ a:issue.key,
		\ a:issue.fields.issuetype.name,
		\ watching,
	\ )

	let dates = printf("%s (updated %s)",
		\ s:date(a:issue.fields.created),
		\ s:date(a:issue.fields.updated),
	\ )

	let assignee = "none"
	if type(a:issue.fields.assignee) == v:t_dict
		let assignee = a:issue.fields.assignee.displayName
	endif
	let assignee = printf("%s (%s)",
		\ assignee,
		\ a:issue.fields.reporter.displayName,
	\ )

	let fix_versions = []
	if type(get(a:issue.fields, "fixVersions", v:null)) == v:t_list
		if len(a:issue.fields.fixVersions) > 0
			let fix_vers = map(copy(a:issue.fields.fixVersions), {k,v -> v.name})
			call reverse(sort(fix_vers, "N"))
			call add(fix_versions, printf("  Version:  %s", join(fix_vers, ", ")))
		endif
	endif

	let sprints = []
	if type(get(a:issue.fields, "customfield_10005", v:null)) == v:t_list
		if len(a:issue.fields.customfield_10005) > 0
			let sprint_list = map(copy(a:issue.fields.customfield_10005),
				\ {k,v -> utils#sprint_short_name(v.name)}
			\ )

			call add(sprints, printf("  Sprints:  (%i) %s",
				\ len(sprint_list),
				\ join(reverse(sort(sprint_list, "N")), ", ")
			\ ))
		endif
	endif

	let parent_issue = []
	if has_key(a:issue.fields, "parent")
		call add(parent_issue, printf("  Parent:   %s %s (%s)",
			\ a:issue.fields.parent.key,
			\ a:issue.fields.parent.fields.summary,
			\ a:issue.fields.parent.fields.status.name,
		\ ))
	endif

	let issuelinks = []
	if type(get(a:issue.fields, "issuelinks", v:null)) == v:t_list
		if len(a:issue.fields.issuelinks) > 0
			call add(issuelinks, "  Issue Links:")
			for link in a:issue.fields.issuelinks
				if has_key(link, "inwardIssue")
					let type = "inward"
				elseif has_key(link, "outwardIssue")
					let type = "outward"
				else
					throw "Unknown issue link type"
				endif

				call add(issuelinks, printf(
					\ "    %s: %s %s (%s)",
					\ s:capitalise(link.type[type]),
					\ link[type . "Issue"].key,
					\ link[type . "Issue"].fields.summary,
					\ link[type . "Issue"].fields.status.name,
				\ ))
			endfor
		endif
	endif

	let issue_history = []
	if has_key(a:issue, "changelog")
		call add(issue_history, "")
		call add(issue_history, "  History:  {{" . "{")

		let counter = 0
		for histlog in a:issue.changelog.histories
			if counter > 0
				call add(issue_history, "")
			endif
			let counter += 1

			call add(issue_history, printf("    %s (%s)",
				\ histlog.author.displayName,
				\ s:date(histlog.created))
			\ )

			for item in histlog.items
				let from_str = item.fromString == v:null ? "" : item.fromString
				let to_str = item.toString == v:null ? "" : item.toString
				call extend(issue_history, [
					\ printf("      %s", s:capitalise(item.field)),
					\ printf("        from '%s'", from_str),
					\ printf("        to   '%s'", to_str),
				\ ])
			endfor
		endfor

		call extend(issue_history, [
			\ "",
			\ printf("    %s (%s)",
				\ a:issue.fields.creator.displayName,
				\ s:date(a:issue.fields.created),
			\ ),
			\ "      Created",
			\ "  }}}",
		\ ])
	endif

	let epic_issues = []
	if a:issue.fields.issuetype.name ==? "epic"
		function! s:get_epic_issues(search_results) abort closure
			let counts = {"all": 0, "done": 0}
			for issue in a:search_results.issues
				call add(epic_issues, s:summarise_issue(issue))
				let counts.all += 1
				if issue.fields.status.name ==# "Done"
					let counts.done += 1
				endif
			endfor

			call insert(epic_issues, printf(
				\ "  Epic Issues (%s/%s, %.0f%%):",
				\ counts.done,
				\ counts.all,
				\ counts.all > 0 ? (100 * counts.done / counts.all) : 0,
			\ ))
			call insert(epic_issues, "")
		endfunction

		let jobid = api#search(
			\ {d -> s:get_epic_issues(d)},
			\ '"epic link" = ' . a:issue.key,
		\ )
		call jobwait([jobid])
	endif

	let description = []
	if a:issue.fields.description != v:null
		let description = [""] + map(
			\ s:wrap(a:issue.fields.description),
			\ {k,v -> substitute(v, "\r", "", "")}
		\ )
	endif

	let comment_entry = []
	if has_key(a:opts, "add_comment") || has_key(a:opts, "edit_comment")
		let header_text = "Add comment"
		let body = [""]
		if has_key(a:opts, "edit_comment")
			let header_text = "Edit comment"

			let comment_to_edit = filter(
				\ copy(a:issue.fields.comment.comments),
				\ {k,v -> v.id == a:opts.edit_comment}
			\ )
			if !empty(comment_to_edit)
				let comment_to_edit = comment_to_edit[0].body
			endif

			let body = split(comment_to_edit, "\n")
		endif

		let comment_entry = [
			\ "",
			\ "-- ".header_text.": " . repeat("-", &columns - len(header_text) - 7),
			\ ""
		\ ] + body + [
			\ "",
			\ "-- End of comment " . repeat("-", &columns - 20)
		\ ]
	endif

	let comments = []
	for comment in reverse(a:issue.fields.comment.comments)
		let head = printf("_%s %s_", comment.author.displayName, s:date(comment.updated))
		let body = map(s:wrap(comment.body), {k,v -> substitute(v, "\r", "", "")})
		call extend(comments, ["", head] + body)
	endfor

	return [
		\ "",
		\ "  " . weblink,
		\ "  Title:    " . a:issue.fields.summary,
		\ "  Assignee: " . assignee,
		\ "  Status:   " . a:issue.fields.status.name,
		\ "  Created:  " . dates,
	\ ]
	\ + fix_versions
	\ + sprints
	\ + parent_issue
	\ + issuelinks
	\ + issue_history
	\ + epic_issues
	\ + description
	\ + comment_entry
	\ + comments
endfunction

function issue_view#load(key, opts) abort
	if match(a:key, '^\u\+-\d\+$') !=# 0
		echoerr "Invalid issue key, " . a:key
		return
	endif

	let orig_win = winnr()

	exe g:jira_issue_win . "wincmd w"
	silent exe printf("edit%s +3 jira://%s", get(a:opts, "reload", 0) ? "!" : "", a:key)
	call issue_view#setup()
	exe orig_win . "wincmd w"
endfunction

function issue_view#read_cmd(file) abort
	let key = matchstr(a:file, 'jira://\zs\u\+-\d\+')
	let buf_nr = bufnr()

	if v:cmdbang
		unlet! b:jira_comment_id
	endif

	let opts = {}
	let comment_id = get(b:, "jira_comment_id", -2)
	if  comment_id == -1
		let opts.add_comment = 1
	elseif comment_id > 0
		let opts.edit_comment = comment_id
	endif

	function! s:view_issue_callback(data) abort closure
		let issue = s:format_issue(a:data, opts)

		call setbufvar(buf_nr, "&modifiable", 1)
		silent call deletebufline(buf_nr, 1, "$")
		call setbufline(buf_nr, 1, issue)
		call setbufvar(buf_nr, "jira_key", key)
	endfunction

	call api#get_issue(
		\ {data -> s:view_issue_callback(data)},
		\ key,
		\ v:cmdbang,
	\ )
endfunction

function s:save_post_comment(key) abort
	let end_marker = search("^-- End of comment --", "n")

	if ! has_key(b:, "jira_comment_id")
		return
	endif

	if b:jira_comment_id == -1
		let start_marker = search("^-- Add comment: --", "n")
		let comment_mode = "add"
	elseif b:jira_comment_id > 0
		let start_marker = search("^-- Edit comment: --", "n")
		let comment_mode = "edit"
	else
		throw "Invalid value for b:jira_comment_id, '" . b:jira_comment_id . "'"
	endif

	if start_marker <= 0 || end_marker <= 0
		echo "You've changed the comment markers!"
		return
	endif

	let comment = trim(join(getline(start_marker + 1, end_marker - 1), "\n"))

	if empty(comment)
		call issue_view#load(a:key, {})
		return
	endif

	echo "Posting comment for issue " . a:key . " (" . len(comment) . " bytes)"
	call api#comment_on_issue(
		\ {-> issue_view#load(a:key, {"reload": 1})},
		\ a:key,
		\ comment,
		\ b:jira_comment_id,
	\ )

	unlet! b:jira_comment_id
endfunction

function s:do_transition(key, ...) abort
	let Callback = {state_id -> api#transition_issue(
		\ {-> issue_view#load(a:key, {"reload": 1})},
		\ a:key,
		\ state_id
	\ )}

	if a:0 > 0
		let valid_states = filter(copy(s:transition_states), {k,v -> v.name ==? a:1})
		if empty(valid_states)
			echo "Invalid transition, " . a:1
			return
		endif
		let state = valid_states[0]
		call Callback(state.id)
	else
		call api#get_transitions(
			\ {transitions -> choose#transition(Callback, transitions.transitions)},
			\ a:key
		\ )
	endif
endfunction

function s:do_comment(key) abort
	let b:jira_comment_id = -1

	call issue_view#load(a:key, {"add_comment": ""})

	call search("^-- Add comment: --------")
	normal 2j
	setlocal modifiable
	setlocal buftype=acwrite
endfunction

function s:edit_comment(key) abort
	function! s:_edit_commit(comment) abort closure
		let b:jira_comment_id = a:comment.id

		call issue_view#load(a:key, {"edit_comment": a:comment.id})

		call search("^-- Edit comment: --------")
		normal 2j
		setlocal modifiable
		setlocal buftype=acwrite
	endfunction

	call api#get_issue(
		\ {issue -> choose#comment(
			\ {comment -> s:_edit_commit(comment)},
			\ issue.fields.comment.comments
		\ )},
		\ a:key,
		\ 0
	\ )
endfunction

function s:do_claim(key) abort
	call api#claim_issue({-> issue_view#load(a:key, {"reload": 1})}, a:key)
endfunction

function s:do_watch(key) abort
	call api#watch_issue({-> issue_view#load(a:key, {"reload": 1})}, a:key)
endfunction

function s:list_watchers(key) abort
	function! s:_list_watchers(watchers) abort closure
		echo join(
			\ [printf("%s has %i watchers:", a:key, a:watchers.watchCount)]
			\ + sort(map(a:watchers.watchers, {k,v -> "  " . v.displayName})),
			\ "\n"
		\ )
	endfunction

	call api#get_watchers({watchers -> s:_list_watchers(watchers)}, a:key)
endfunction

function s:assign_issue_to_sprint(key) abort
	call choose#board(
		\ {board -> choose#sprint(
			\ {sprint -> api#assign_issue_to_sprint(
				\ {-> issue_view#load(a:key, {"reload": 1})},
				\ a:key,
				\ sprint.id,
			\ )},
			\ board.id,
		\ )}
	\ )
endfunction

function s:assign_issue_to_epic(key) abort
	call choose#board(
		\ {board -> choose#epic(
			\ {epic -> api#assign_issue_to_epic(
				\ {-> issue_view#load(a:key, {"reload": 1})},
				\ a:key,
				\ epic.id
			\ )},
			\ board.id
		\ )}
	\ )
endfunction

function s:link_issue(key, ...) abort
	let link_key = v:null
	if a:0 > 0
		let link_key = a:000[0]
	else
		let link_key = input("Link to: ")
	endif

	call choose#link_type(
		\ {link -> api#link_issue(
			\ {-> issue_view#load(a:key, {"reload": 1})},
			\ link[2] == "outward" ? link_key : a:key,
			\ link[2] == "outward" ? a:key : link_key,
			\ link[3],
		\ )}
	\ )
endfunction

function s:change_issue_type(key) abort
	call api#get_issue_edit_metadata(
		\ {meta -> choose#issue_type(
			\ {type -> api#set_issue_type(
				\ {-> issue_view#load(a:key, {"reload": 1})},
				\ a:key,
				\ type.id
			\ )},
			\ meta.fields.issuetype.allowedValues
		\ )},
		\ a:key
	\ )
endfunction

function s:get_issue_under_cursor() abort
	let found_match = ""
	let matchpos = matchstrpos(getline("."), '\<\u\+-\d\+\>')
	let curpos = getcurpos()[2]
	while matchpos[1] >= 0
		if curpos > matchpos[1] && curpos <= matchpos[2]
			let found_match = matchpos[0]
			break
		endif
		let matchpos = matchstrpos(getline("."), '\<\u\+-\d\+\>', matchpos[2])
	endwhile
	return found_match
endfunction

function s:summarise_issue_echo(issue)
	if ! utils#issue_is_valid(a:issue)
		if has_key(a:issue, "errorMessages")
			echo join(a:issue.errorMessages, "\n")
		endif
		return "Issue is not valid"
	endif

	echohl Comment
	echon a:issue.key . " "

	echohl None
	echon a:issue.fields.summary . " ("

	let status = a:issue.fields.status.name
	if status == "Done"
		echohl JiraStatusDone
	elseif status == "Blocked"
		echohl JiraStatusBlocked
	elseif status == "In Progress"
		echohl JiraStatusInProgress
	elseif status == "To Do"
		echohl JiraStatusToDo
	endif
	echon status

	echohl None
	echon ")"
endfunction

function s:summarise_issue(issue)
	if ! utils#issue_is_valid(a:issue)
		if has_key(a:issue, "errorMessages")
			echo join(a:issue.errorMessages, "\n")
		endif
		return "Issue is not valid"
	endif

	return printf("%s %s (%s)",
		\ a:issue.key,
		\ a:issue.fields.summary,
		\ a:issue.fields.status.name,
	\ )
endfunction

function s:preview_issue_under_cursor() abort
	let key = s:get_issue_under_cursor()
	if empty(key)
		return
	endif

	call api#get_issue({d -> s:summarise_issue_echo(d)}, key, 0)
endfunction

function s:load_issue_under_cursor() abort
	let key = s:get_issue_under_cursor()
	if empty(key)
		return
	endif
	call issue_view#load(key, {})
endfunction

function issue_view#setup() abort
	syntax clear
	syntax sync fromstart

	setlocal buftype=nofile
	setlocal colorcolumn=0
	setlocal conceallevel=3
	setlocal foldmethod=marker
	setlocal foldtext=substitute(getline(v:foldstart),'[{]{{$','','')
	setlocal formatoptions=roqn
	setlocal nolist
	setlocal nomodifiable
	setlocal nomodified
	setlocal nonumber
	setlocal noswapfile
	setlocal signcolumn=yes:1
	setlocal textwidth=0

	call utils#setup_highlight_groups()

	syntax match JiraTypeTask  ' (\zsTask\ze)'
	syntax match JiraTypeBug   ' (\zsBug\ze)'
	syntax match JiraTypeStory ' (\zsStory\ze)'
	syntax match JiraTypeEpic  ' (\zsEpic\ze)'

	syntax match JiraKey '\u\{2,}-\d\+'
	syntax match JiraTitle '^\s*Title: \+\zs.*'
	syntax match JiraAssigneeNone '^\s*Assignee: \+\zsnone'

	syntax match JiraStatusDone       '^\s*Status: \+\zsDone'
	syntax match JiraStatusBlocked    '^\s*Status: \+\zsBlocked'
	syntax match JiraStatusInProgress '^\s*Status: \+\zsIn Progress'
	syntax match JiraStatusToDo       '^\s*Status: \+\zsTo Do'
	syntax match JiraStatusDone       '(\zsDone\ze)$'
	syntax match JiraStatusBlocked    '(\zsBlocked\ze)$'
	syntax match JiraStatusInProgress '(\zsIn Progress\ze)$'
	syntax match JiraStatusToDo       '(\zsTo Do\ze)$'

	exe 'syntax match JiraMe "\V'.utils#get_display_name().'"'
	syntax match JiraCommentHeader '^\n.*\d\d\d\d-\d\d-\d\d \d\d:\d\d$'
	syntax match JiraCommentHeader '^\n_[^_]\+_$'

	syntax region JiraCommentEntry
		\ start='^-- Add comment: --*$'
		\ start='^-- Edit comment: --*$'
		\ end='^-- End of comment --*$'

	nnoremap <buffer> <silent> R :call issue_view#load(b:jira_key, {"reload": 1})<CR>
	nnoremap <buffer> <silent> <CR> :call <SID>preview_issue_under_cursor()<CR>
	nnoremap <buffer> <silent> <C-]> :call <SID>load_issue_under_cursor()<CR>
	nnoremap <buffer> u :set modifiable <bar> undo <bar> set nomodifiable<CR>
	nnoremap <buffer> gx :call system(["xdg-open", utils#get_issue_url(b:jira_key)])<CR>

	function! s:complete_transition(A, L, P) abort
		return join(map(copy(s:transition_states), 'v:val.name'), "\n")
	endfunction

	command! -buffer -nargs=0 JiraComment :call <SID>do_comment(b:jira_key)
	command! -buffer -nargs=0 JiraEditComment :call <SID>edit_comment(b:jira_key)
	command! -buffer -nargs=0 JiraClaim :call <SID>do_claim(b:jira_key)
	command! -buffer -nargs=0 JiraWatch :call <SID>do_watch(b:jira_key)
	command! -buffer -nargs=0 JiraWatchers :call <SID>list_watchers(b:jira_key)
	command! -buffer -nargs=?
		\ -complete=custom,<SID>complete_transition
		\ JiraTransition :call <SID>do_transition(b:jira_key, <f-args>)
	command! -buffer -nargs=0 JiraAssignToSprint :call <SID>assign_issue_to_sprint(b:jira_key)
	command! -buffer -nargs=? JiraLink :call <SID>link_issue(b:jira_key, <f-args>)
	command! -buffer -nargs=0 JiraChangeType :call <SID>change_issue_type(b:jira_key)
	command! -buffer -nargs=0 JiraAssignToEpic :call <SID>assign_issue_to_epic(b:jira_key)

	augroup issue_buf
		autocmd!
		autocmd BufWriteCmd <buffer> :call <SID>save_post_comment(b:jira_key)
	augroup END
endfunction

function issue_view#open() abort
	execute printf("%.0fsplit", winheight(0) * 0.75)
	execute "buffer " . g:jira_issue_buffer
endfunction

function issue_view#toggle() abort
	let cur_win_id = win_getid()
	let win = win_findbuf(g:jira_issue_buffer)
	if empty(win)
		" enable issue view
		let key_to_view = utils#get_key()
		call issue_view#open()
		call issue_view#load(key_to_view, {})
		call win_gotoid(cur_win_id)
		return
	endif

	" disable issue view
	let winnr = win_id2win(win[0])
	if winnr > 0
		execute winnr.'wincmd c'
	endif
endfunction
