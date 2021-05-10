let s:username = ""
let s:password = ""

let s:display_name = ""
let s:account_id = ""

let s:web_url = ""
let s:cache_dir = fnamemodify("~/.cache/jira", ":p")

let s:saved_queries = {
	\ "mysprint": 'project = DN AND sprint IN openSprints() AND status != Done AND assignee IN (currentUser(), empty) ORDER BY assignee, updated',
	\ "sprint": 'project = DN AND sprint IN (openSprints(), futureSprints()) ORDER BY sprint, status, rank',
	\ "me": 'assignee = currentUser() AND status != Done',
	\ "recent": 'project = DN AND updated > -1d ORDER BY updated',
	\ "backlog": 'project = DN AND status != Done ORDER BY sprint desc, rank',
\ }

let s:status_abbreviations = {
	\ "Blocked": "B",
	\ "Done": "D",
	\ "In Progress": "P",
	\ "Open": "O",
	\ "To Do": "T",
\ }

let s:issue_type_abbreviations = {
	\ "Bug": "B",
	\ "Epic": "E",
	\ "Story": "S",
	\ "Task": "T",
\ }

" Data functions (getters) -------------------------

function utils#get_display_name() abort
	if empty(s:display_name)
		call utils#set_myself()
	endif
	return s:display_name
endfunction

function utils#get_issue_url(key) abort
	return s:web_url . "/browse/" . a:key
endfunction

function utils#get_username()
	return s:username
endfunction

function utils#get_password()
	return s:password
endfunction

function utils#get_account_id()
	if empty(s:account_id)
		call utils#set_myself()
	endif
	return s:account_id
endfunction

function utils#get_saved_queries()
	return s:saved_queries
endfunction

function utils#get_status_abbreviations()
	return s:status_abbreviations
endfunction

function utils#get_issue_type_abbreviations()
	return s:issue_type_abbreviations
endfunction

" Utility functions ----------------------------

function utils#echo(...) abort
	echo join(a:000, "\n")
endfunction

function utils#set_myself() abort
	function! s:set_myself(data, fname) abort
		let s:display_name = a:data.displayName
		let s:account_id = a:data.accountId
		if ! empty(a:fname)
			call writefile([json_encode(a:data)], a:fname)
		endif
	endfunction

	let cache_file = utils#cache_file("myself.json")
	if filereadable(cache_file)
		let myself = json_decode(join(readfile(cache_file), "\n"))
		call s:set_myself(myself, "")
	else
		let jobid = api#get_myself({d -> s:set_myself(d, cache_file)})
		call jobwait([jobid])
	endif
endfunction

function utils#get_initials(name) abort
	return substitute(a:name, '\(\u\)[^ ]\+ \?', '\1', "g")
endfunction

function utils#cache_file(fname) abort
	call mkdir(s:cache_dir, "p")
	return s:cache_dir . a:fname
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
	if has_key(b:, "jira_key")
		return b:jira_key
	endif

	if line(".") == 1
		return
	endif

	return matchstr(getline("."), '^ \?\zs\u\+-\d\+')
endfunction

function utils#sprint_short_name(name) abort
	return substitute(a:name, '\(DevOps\|Exonar\) Sprint ', "", "")
endfunction

function utils#issue_is_valid(issue) abort
	if ! type(a:issue) == v:t_dict
		return 0
	endif

	if ! has_key(a:issue, "key") || ! has_key(a:issue, "fields")
		return 0
	endif

	return 1
endfunction

function utils#clamp(str, len) abort
	return strdisplaywidth(a:str) <= a:len
		\ ? a:str
		\ : (strcharpart(a:str, 0, a:len - 1) . "…")
endfunction
