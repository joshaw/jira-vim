let g:jira_status_abbreviations = get(g:, "jira_status_abbreviations", {
	\ "Blocked": "B",
	\ "Done": "D",
	\ "In Progress": "P",
	\ "Open": "O",
	\ "To Do": "T",
	\ "New": "T",
\ })

let g:jira_issue_type_abbreviations = get(g:, "jira_issue_type_abbreviations", {
	\ "Bug": "B",
	\ "Epic": "E",
	\ "Story": "S",
	\ "Task": "T",
\ })

" Getter functions -------------------------

function utils#get_display_name() abort
	return get(s:get_myself(), "display_name", "")
endfunction

function utils#get_issue_url(key) abort
	return g:jira_base_url . "/browse/" . a:key
endfunction

function utils#get_username() abort
	return get(g:, "jira_username", "")
endfunction

function utils#get_password() abort
	return get(g:, "jira_password", "")
endfunction

function utils#get_agile_url() abort
	return g:jira_base_url . "/rest/agile/1.0"
endfunction

function utils#get_atlassian_url() abort
	return g:jira_base_url . "/rest/api/2"
endfunction

function utils#get_account_id() abort
	return get(s:get_myself(), "account_id", "")
endfunction

function utils#get_saved_queries() abort
	let default_default = "assignee = currentUser() ORDER BY updated"
	let queries = get(g:, "jira_saved_queries", {})
	let queries.default = get(queries, "default", default_default)
	return queries
endfunction

function utils#get_status_abbreviations() abort
	return g:jira_status_abbreviations
endfunction

function utils#get_issue_type_abbreviations() abort
	return g:jira_issue_type_abbreviations
endfunction

" Utility functions ----------------------------

function utils#echo(msg) abort
	if type(a:msg) == v:t_string
		echo a:msg
		return
	endif

	if type(a:msg) == v:t_list
		" A list of just strings
		if uniq(map(copy(a:msg), {k,v -> type(v)})) == [v:t_string]
			echo join(a:msg, "\n")
			return
		endif
	endif

	echo string(a:msg)
endfunction

function s:get_myself() abort
	function! s:set_myself(data, fname) abort
		let s:display_name = get(a:data, "displayName", -1)
		let s:account_id = get(a:data, "accountId", -1)
		if s:display_name != -1 && s:account_id != -1 && ! empty(a:fname)
			let a:data.username = utils#get_username()
			call writefile([json_encode({
				\ "username": a:data.username,
				\ "accountId": s:account_id,
				\ "displayName": s:display_name,
			\ })], a:fname)
		endif
	endfunction

	let cache_file = utils#cache_file("myself.json")
	let myself = {}
	if filereadable(cache_file)
		let myself = json_decode(join(readfile(cache_file), "\n"))
	endif

	if sort(keys(myself)) == ["accountId", "displayName", "username"]
			\ && myself.username == utils#get_username()
		call s:set_myself(myself, "")
	else
		let jobid = api#get_myself({d -> s:set_myself(d, cache_file)})
		call jobwait([jobid])
	endif
	return {"display_name": s:display_name, "account_id": s:account_id}
endfunction

function utils#get_initials(name) abort
	return substitute(a:name, '\(\u\)[^ ]\+ \?', '\1', "g")
endfunction

function utils#cache_file(fname) abort
	let dir = get(environ(), "XDG_CACHE_HOME", fnamemodify(expand("$HOME/.cache/"), ":p"))
	let dir .= "/jira/"

	let cache_dir = get(g:, "jira_cache_dir", dir) . "/"
	let cache_dir = substitute(cache_dir, '/\+', "/", "g")

	call mkdir(cache_dir, "p")
	return cache_dir . a:fname
endfunction

function utils#setup_highlight_groups() abort
	highlight link JiraTypeTask Identifier
	highlight link JiraTypeBug Keyword
	highlight link JiraTypeStory Function
	highlight link JiraTypeEpic Directory

	highlight link JiraKey Comment
	highlight link JiraTitle Title

	highlight link JiraAssigneeNone Comment
	highlight link JiraAssigneeMe Title

	highlight link JiraStatusDone Function
	highlight link JiraStatusBlocked Exception
	highlight link JiraStatusInProgress Label
	highlight link JiraStatusToDo Identifier

	highlight link JiraMe Underlined

	highlight link JiraCommentHeader PmenuSel
	highlight link JiraCommentEntry Comment

	highlight link JiraPrompt Operator
	highlight link JiraPromptCount Whitespace
	"highlight link JiraQuery Title

	highlight link JQLKeywords Keyword
	highlight link JQLOperators Keyword
	highlight link JQLFunctions Function
	highlight link JQLString String
	highlight link JQLFields Constant
endfunction

function utils#goto_buffer(buf) abort
	let win = win_findbuf(a:buf)
	if empty(win)
		return
	endif
	call win_gotoid(win[0])
endfunction

function utils#get_key() abort
	if has_key(b:, "jira_issue")
		return b:jira_issue.key
	endif

	if line(".") == 1
		return "summary"
	endif

	return matchstr(getline("."), '^ \?\zs\u\+-\d\+')
endfunction

function utils#key_is_valid(key) abort
	return match(a:key, '\u\+-\d\+') >= 0
endfunction

function utils#issue_is_valid(issue) abort
	if type(a:issue) != v:t_dict
		return 0
	endif

	if ! utils#has_keys(a:issue, ["key", "fields"])
		return 0
	endif

	return 1
endfunction

function utils#clamp(str, len) abort
	return strdisplaywidth(a:str) <= a:len
		\ ? a:str
		\ : (strcharpart(a:str, 0, a:len - 1) . "…")
endfunction

function! utils#human_bytes(bytes) abort
	let bytes = a:bytes
	let sizes = ['B', 'KB', 'MB', 'GB']
	let i = 0
	while bytes >= 1024
		let bytes /= 1024.0
		let i += 1
	endwhile
	return bytes > 0 ? printf('%.1f%s', bytes, sizes[i]) : ''
endfunction

function utils#has_keys(dict, keys) abort
	for key in a:keys
		if ! has_key(a:dict, key)
			return 0
		endif
	endfor
	return 1
endfunction

function utils#tab_align(list) abort
	let widths = []
	for line in a:list
		let i = 0
		for item in line
			let item = type(item) == v:t_string ? item : string(item)
			if i >= len(widths)
				call add(widths, strdisplaywidth(item))
			else
				let widths[i] = max([strdisplaywidth(item), widths[i]])
			endif
			let i += 1
		endfor
	endfor

	let output = []
	for line in a:list
		let i = 0
		let new_line = []
		for item in line
			let item = type(item) == v:t_string ? item : string(item)
			if i == len(widths) - 1
				call add(new_line, item)
			else
				call add(new_line, item . repeat(" ", widths[i] - strdisplaywidth(item)))
			endif
			let i += 1
		endfor
		call add(output, join(new_line, " "))
	endfor

	return output
endfunction
