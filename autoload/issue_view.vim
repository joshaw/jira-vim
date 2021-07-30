function s:wrap(str) abort
	"return split(a:str, "\n")
	return systemlist(["fmt", "-s"], a:str)
endfunction

function s:plural(num) abort
	return floor(a:num) > 1 ? "s" : ""
endfunction

let s:date_cache = {}
function s:date(str) abort
	if has_key(s:date_cache, a:str)
		let date_ts = s:date_cache[a:str]
	else
		" Remove fractional seconds
		let str = substitute(a:str, '\.\d\++', "+", "")
		if has("*strptime")
			let date_ts = strptime("%Y-%m-%dT%H:%M:%S%z", str)
		elseif has("macunix")
			let date_ts = str2nr(systemlist(["date", "-j", "-f", "%FT%T%z", str, "+%s"])[0])
		else
			let date_ts = str2nr(systemlist(["date", "--date", a:str, "+%s"])[0])
		endif
	endif

	let s:date_cache[a:str] = date_ts

	let secs = localtime() - date_ts
	if secs < 60 | return printf("%.0f second%s ago", secs, s:plural(secs)) | endif

	let mins = secs / 60
	if mins < 91 | return printf("%.0f minute%s ago", mins, s:plural(mins)) | endif

	let hours = mins / 60
	if hours < 35 | return printf("%.0f hour%s ago", hours, s:plural(hours)) | endif

	let days = hours / 24
	if days < 21 | return printf("%.0f day%s ago", days, s:plural(days)) | endif

	return strftime("%Y-%m-%d %H:%M", date_ts)
endfunction

function s:capitalise(str) abort
	return toupper(a:str[0]) . a:str[1:]
endfunction

function s:substitute_users(str) abort
	let f_users = utils#cache_file("users.json")
	if !filereadable(f_users)
		return a:str
	endif

	if !has_key(g:, "jira_users")
		let g:jira_users = json_decode(readfile(f_users))
	endif

	return substitute(
		\ a:str,
		\ '\[\~accountid:\([0-9a-f:-]\+\)\]',
		\ {m -> "@" . substitute(get(g:jira_users, m[1], m[1]), " ", "_", "g")},
		\ "g"
	\ )
endfunction

function s:format_links(str) abort
	let str = a:str

	" [ title | url | type ] -> [ title | url ]
	let str = substitute(
		\ str,
		\ '\[\([^|\]]\+\)|\(https\?:\/\/[^|\]]\+\)|\([^|\]]\+\)\]',
		\ '[\1|\2]',
		\ "g"
	\ )

	" [ url | url ] -> url
	let str = substitute(
		\ str,
		\ '\[\(https\?:\/\/[^|\]]\+\)|\1\]',
		\ '\1',
		\ "g"
	\ )

	" [ title | url ] -> title (url)
	let str = substitute(
		\ str,
		\ '\[\([^|\]]\+\)|\(https\?:\/\/[^|\]]\+\)\]',
		\ '\1 (\2)',
		\ "g"
	\ )

	return str
endfunction

function s:format_issue(issue, opts) abort
	if ! utils#issue_is_valid(a:issue)
		if type(a:issue) == v:t_dict && has_key(a:issue, "errorMessages")
			return ["Error:"] + a:issue.errorMessages
		endif
		return [json_encode(a:issue)]
	endif

	let watching = has_key(a:issue.fields, "watches")
		\ ? printf(" (w%s/%i)",
			\ a:issue.fields.watches.isWatching ? "+" : "-",
			\ a:issue.fields.watches.watchCount
		\ )
		\ : ""

	let weblink = printf("%s (%s)%s",
		\ utils#get_issue_url(a:issue.key),
		\ a:issue.fields.issuetype.name,
		\ watching,
	\ )

	let dates = printf("%s (updated %s)",
		\ s:date(a:issue.fields.created),
		\ s:date(a:issue.fields.updated),
	\ )

	let assignee = printf("%s (reported by %s)",
		\ type(a:issue.fields.assignee) == v:t_dict
			\ ? a:issue.fields.assignee.displayName
			\ : "none",
		\ a:issue.fields.reporter.displayName,
	\ )

	let fix_versions = get(a:issue.fields, "fixVersions", v:null)
	if type(fix_versions) == v:t_list && len(fix_versions) > 0
		call map(fix_versions, {k,v -> v.name})
		call reverse(sort(fix_versions, "N"))
		let fix_versions = [printf("Fixed in: %s", join(fix_versions, ", "))]
	endif

	let affects_versions = get(a:issue.fields, "versions", v:null)
	if type(affects_versions) == v:t_list && len(affects_versions) > 0
		call map(affects_versions, {k,v -> v.name})
		call reverse(sort(affects_versions, "N"))
		let affects_versions = [printf("Affects:  %s", join(affects_versions, ", "))]
	endif

	let components = get(a:issue.fields, "components", v:null)
	if type(components) == v:t_list && len(components) > 0
		call map(components, {k,v -> v.name})
		let components = [printf("Components:  %s", join(components, ", "))]
	endif

	let sprints = []
	let orig_sprints = get(a:issue.fields, "customfield_10005", [])
	if type(orig_sprints) == v:t_list && len(orig_sprints) > 0
		let sprint_list = map(copy(orig_sprints), {k,v -> v.name})

		let sprints = [printf("Sprints:  (%i) %s",
			\ len(sprint_list),
			\ join(reverse(sort(sprint_list, "N")), ", ")
		\ )]
	endif

	let parent_issue = has_key(a:issue.fields, "parent")
		\ ? [printf("Parent:   %s %s (%s)",
			\ a:issue.fields.parent.key,
			\ a:issue.fields.parent.fields.summary,
			\ a:issue.fields.parent.fields.status.name,
		\ )]
		\ : []

	let issuelinks = []
	let orig_issuelinks = get(a:issue.fields, "issuelinks", [])
	if type(orig_issuelinks) == v:t_list && len(orig_issuelinks) > 0
		call add(issuelinks, "Issue Links:")
		for link in orig_issuelinks
			if has_key(link, "inwardIssue")
				let type = "inward"
			elseif has_key(link, "outwardIssue")
				let type = "outward"
			else
				throw "Unknown issue link type"
			endif

			call add(issuelinks, printf(
				\ "  %s: %s %s (%s)",
				\ s:capitalise(link.type[type]),
				\ link[type . "Issue"].key,
				\ link[type . "Issue"].fields.summary,
				\ link[type . "Issue"].fields.status.name,
			\ ))
		endfor
	endif

	let issue_history = []
	if has_key(a:issue, "changelog")
		call add(issue_history, "")
		call add(issue_history, "History: ⟪⟪")

		let counter = 0
		for histlog in a:issue.changelog.histories
			if counter > 0
				call add(issue_history, "")
			endif
			let counter += 1

			call add(issue_history, printf("  %s (%s)",
				\ histlog.author.displayName,
				\ s:date(histlog.created))
			\ )

			for item in histlog.items
				let from_str = item.fromString == v:null ? "" : item.fromString
				let to_str = item.toString == v:null ? "" : item.toString
				call extend(issue_history, [
					\ "    " . s:capitalise(item.field),
					\ "      from '" . from_str . "'",
					\ "      to   '" . to_str . "'",
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
			\ "⟫⟫",
		\ ])
	endif

	let epic_issues = []
	if has_key(a:issue.fields, "epic_issues")
		let counts = {"all": 0, "done": 0}
		for epic_issue in a:issue.fields.epic_issues
			call add(epic_issues, "    " . s:summarise_issue(epic_issue))
			let counts.all += 1
			if epic_issue.fields.status.category ==# "Done"
				let counts.done += 1
			endif
		endfor

		call insert(epic_issues, printf(
			\ "Epic Issues (%s/%s, %.0f%%):",
			\ counts.done,
			\ counts.all,
			\ counts.all > 0 ? (100 * counts.done / counts.all) : 0,
		\ ))
		call insert(epic_issues, "")
	endif

	let checklist = []
	let checklist_str = get(a:issue.fields, "customfield_12055", 0)
	if type(checklist_str) ==# v:t_string && !empty(trim(checklist_str))
		let checklist = ["", "Checklist:"]
		let done = 0
		let undone = 0
		for item in split(checklist_str, "\n")
			let item = substitute(item, '^\* ', "", "")
			let item = substitute(item, '^- ', "", "")
			if item =~# '^>> '
				continue
			elseif item =~# '^--- '
				let item = "  " . item
			elseif item =~# '^\[x\]'
				let done += 1
				let item = "  [x] " . item[4:]
			elseif item =~# '^\[\]'
				let undone += 1
				let item = "  [ ] " . item[3:]
			else
				let undone += 1
				let item = "  [ ] " . item
			endif
			call add(checklist, item)
		endfor
		let checklist[1] = printf("Checklist (%i/%i, %.0f%%):", done, done + undone, 100 * done / (done + undone))
	endif

	let description = []
	let description_str = a:issue.fields.description
	if type(description_str) ==# v:t_string && len(trim(description_str)) > 0
		let description = map(
			\ s:wrap(s:substitute_users(s:format_links(description_str))),
			\ {k,v -> substitute(substitute(v, "\r", "", ""), '^\|\n\zs', '│ ', "g")}
		\ )

		let line = repeat("─", 20) . "┄"
		let description = ["", "╭" . line] + description + ["╰" . line]
	endif

	let header_text = "Add comment"
	let body = [""]
	if get(a:opts, "comment", -1) > 0
		let header_text = "Edit comment"

		let comment_to_edit = filter(
			\ copy(a:issue.fields.comment.comments),
			\ {k,v -> v.id == a:opts.comment}
		\ )
		if !empty(comment_to_edit)
			let comment_to_edit = comment_to_edit[0].body
		endif
		let body = split(comment_to_edit, "\n")
	endif

	let columns = winwidth(0)
	let comment_entry = [
		\ "",
		\ "-- ".header_text.": ⟪⟪",
		\ "",
	\ ] + body + [
		\ "",
		\ "-- End of comment ⟫⟫"
	\ ]

	let comments = []
	let ordered_comment_list = get(g:, "jira_comments_newest_first", 0)
		\ ? reverse(copy(a:issue.fields.comment.comments))
		\ : a:issue.fields.comment.comments

	for comment in ordered_comment_list
		let head = printf("❱ %s %s", comment.author.displayName, s:date(comment.updated))
		let comment.body = s:substitute_users(s:format_links(comment.body))
		let body = map(s:wrap(comment.body), {k,v -> substitute(v, "\r", "", "")})
		call extend(comments, ["", head] + body)
	endfor

	return [
		\ "",
		\ "" . weblink,
		\ "Title:    " . a:issue.fields.summary,
		\ "Assignee: " . assignee,
		\ "Status:   " . a:issue.fields.status.name,
		\ "Created:  " . dates,
	\ ]
	\ + fix_versions
	\ + affects_versions
	\ + components
	\ + sprints
	\ + parent_issue
	\ + issuelinks
	\ + issue_history
	\ + epic_issues
	\ + description
	\ + checklist
	\ + comment_entry
	\ + comments
endfunction

function issue_view#load(key) abort
	silent exe "edit jira://" . a:key
endfunction

function issue_view#load_previous_window(key) abort
	if len(getwininfo()) < 2
		return
	endif

	" Go to previous window
	let orig_win = win_getid()
	wincmd p

	call issue_view#load(a:key)
	call win_gotoid(orig_win)
endfunction

function s:view_issue_callback(data, buf_nr) abort
	call setbufvar(a:buf_nr, "jira_issue", a:data)
	let issue = s:format_issue(a:data, {"comment": get(b:, "jira_comment_id", -1)})

	silent call deletebufline(a:buf_nr, 1, "$")
	call setbufline(a:buf_nr, 1, issue)
	call setbufvar(a:buf_nr, "&modified", 0)
endfunction

function issue_view#reload(key) abort
	let buf_nr = bufnr("jira://" . a:key)
	return api#get_issue(
		\ {data -> s:view_issue_callback(data, buf_nr)},
		\ a:key,
		\ 1,
	\ )
endfunction

function issue_view#read_cmd(file) abort
	call issue_view#setup()

	let buf_nr = bufnr()

	silent call deletebufline(buf_nr, 1, "$")

	if a:file ==# "jira://summary"
		call issue_view#set_summary(g:jira_query_data, buf_nr)
	elseif a:file ==# "jira://create"
		call issue_view#set_create(buf_nr)
	else
		let key = matchstr(a:file, 'jira://\zs\u\+-\d\+')
		call setbufline(buf_nr, 1, ["", "Loading..."])
		call api#get_issue(
			\ {data -> s:view_issue_callback(data, buf_nr)},
			\ key,
			\ v:cmdbang,
		\ )
	endif
endfunction

function issue_view#set_create(buf_nr) abort
	let buf_contents = readfile(utils#cache_file("create.txt"))

	silent call deletebufline(a:buf_nr, 1, "$")
	call setbufline(a:buf_nr, 1, buf_contents)
	call setbufvar(a:buf_nr, "&modified", 0)
endfunction

function issue_view#set_summary(data, buf_nr) abort
	if has_key(a:data, "errorMessages")
		return
	endif

	let totals = {"statuses": {}, "projects": {}, "assignees": {}, "types": {}}
	for issue in a:data.issues
		let status = issue.fields.status.name
		let totals.statuses[status] = get(totals.statuses, status, 0) + 1

		let type = issue.fields.issuetype.name
		let totals.types[type] = get(totals.types, type, 0) + 1

		let project = split(issue.key, "-")[0]
		let totals.projects[project] = get(totals.projects, project, 0) + 1

		let assignee = type(issue.fields.assignee) == v:t_dict
			\ ? issue.fields.assignee.displayName
			\ : "none"
		let totals.assignees[assignee] = get(totals.assignees, assignee, 0) + 1
	endfor

	let text = [""]

	let shown = a:data.total > a:data.maxResults
		\ ? printf(
			\ " (showing %i to %i of %i)",
			\ a:data.startAt + 1,
			\ a:data.startAt + a:data.maxResults,
			\ a:data.total
		\ )
		\ : ""
	call add(text, printf("Total issues: %i%s", a:data.total, shown))

	function! s:format_list(list, title) abort closure
		call add(text, "")
		let i = 0
		for [item, count] in sort(items(a:list), {a,b -> b[1] - a[1]})
			let title = i == 0 ? a:title : ""
			call add(text, printf("%8s %3i %s", title, count, item))
			let i += 1
		endfor
	endfunction

	call s:format_list(totals.projects,  "Project")
	call s:format_list(totals.statuses,  "Status")
	call s:format_list(totals.types,     "Type")
	call s:format_list(totals.assignees, "Assignee")

	"call add(text, "")
	"call extend(text, systemlist(["jq", "-S", "."], json_encode(a:data)))

	silent call deletebufline(a:buf_nr, 1, "$")
	call setbufline(a:buf_nr, 1, text)
	call setbufvar(a:buf_nr, "&modified", 0)
endfunction

function s:write_cmd_create() abort
	"TODO
	let new_issue = {}
	let desc_start = 0
	for line in getline(0, '$')
		let desc_start += 1
		let parts = split(line, ":", 1)
		if len(parts) != 2
			continue
		endif

		let parts[1] = trim(parts[1])

		if parts[0] ==# "Reporter"
			let new_issue.reporter = {"displayName": parts[1]}
		elseif parts[0] ==# "Project"
			let new_issue.project = {"key": parts[1]}
		elseif parts[0] ==# "Issue Type"
			let new_issue.issueType = {"name": parts[1]}
		elseif parts[0] ==# "Summary"
			let new_issue.summary = parts[1]
		elseif parts[0] ==# "Description"
			break
		endif
	endfor

	let new_issue.description = trim(join(getline(desc_start, "$"), "\n"))
	echo json_encode(new_issue)
	setlocal nomodified
	call issue_view#load("DN-1997")
	" TODO: test this
	"call api#create_issue({issue -> issue_view#load(issue.key)}, new_issue)
endfunction

function s:write_cmd_comment(key) abort
	let start_marker = get(b:, "jira_comment_id", 0) > 0
		\ ? search("^-- Edit comment: ⟪⟪$", "n")
		\ : search("^-- Add comment: ⟪⟪$", "n")

	let end_marker = search("^-- End of comment ⟫⟫$", "n")

	if start_marker <= 0 || end_marker <= 0 || end_marker < start_marker
		echo "You've changed the comment markers!"
		return
	endif

	let comment = trim(join(getline(start_marker + 1, end_marker - 1), "\n"))

	if empty(comment)
		setlocal nomodified
		call issue_view#load(a:key)
		echo "No comment, " . a:key
		return
	endif

	echo "Posting comment for issue " . a:key . " (" . len(comment) . " bytes)"
	call api#comment_on_issue(
		\ {-> issue_view#reload(a:key)},
		\ a:key,
		\ comment,
		\ get(b:, "jira_comment_id", 0),
	\ )

	unlet! b:jira_comment_id
	setlocal nomodified
endfunction

function issue_view#write_cmd(fname) abort
	if a:fname ==# "jira://create"
		call s:write_cmd_create()
		return
	endif

	let key = matchstr(a:fname, '^jira://\zs[A-Z]\+-[0-9]\+$')
	if !empty(key)
		call s:write_cmd_comment(key)
		return
	endif

	echoerr "Don't know how to write " . a:fname
endfunction

function s:do_transition(issue, ...) abort
	let Callback = {state -> api#transition_issue(
		\ {-> issue_view#reload(a:issue.key)},
		\ a:issue.key,
		\ state.id
	\ )}

	let transitions = a:issue.transitions

	if a:0 > 0
		let valid_states = filter(copy(transitions), {k,v -> v.name ==? a:1})
		if empty(valid_states)
			echo "Invalid transition, " . a:1
			return
		endif
		let state = valid_states[0]
		call Callback(state)
	else
		call choose#transition(Callback, transitions)
	endif
endfunction

function s:edit_comment(issue) abort
	function! s:_edit_commit(comment) abort closure
		let b:jira_comment_id = a:comment.id

		let jobid = issue_view#reload(a:issue.key)
		call jobwait([jobid])

		call search("^-- Edit comment: ⟪⟪")

		" 1 Open the fold,
		" 2 move to the start of the comment and
		" 3 center on screen
		normal zO2jzt
	endfunction

	call choose#comment(
		\ {comment -> s:_edit_commit(comment)},
		\ a:issue.fields.comment.comments
	\ )
endfunction

function s:edit_summary(issue) abort
	call api#set_issue_summary(
		\ {-> issue_view#reload(a:issue.key)},
		\ a:issue.key,
		\ input({"prompt": "New summary: ", "default": a:issue.fields.summary})
	\ )
endfunction

function s:do_claim(key) abort
	call api#claim_issue({-> issue_view#reload(a:key)}, a:key)
endfunction

function s:do_start(issue) abort
	let jobid = api#claim_issue({-> 1}, a:issue.key)
	call jobwait([jobid])

	call api#transition_issue(
		\ {-> issue_view#reload(a:issue.key)},
		\ a:issue.key,
		\ filter(copy(a:issue.transitions), {k,v -> v.name ==? "In Progress"})[0].id
	\ )
endfunction

function s:do_watch(key) abort
	call api#watch_issue({-> issue_view#reload(a:key)}, a:key)
endfunction

function s:list_watchers(key) abort
	function! s:print_watchers(watchers) abort closure
		if a:watchers.watchCount > 0 && len(a:watchers.watchers) == 0
			let extra_msg = ", but you don't have permission to list them."
		elseif len(a:watchers.watchers) == 0
			let extra_msg = "."
		else
			let list = join(sort(map(
				\ a:watchers.watchers,
				\ {k,v -> "  " . v.displayName}
			\ )), "\n")
			let extra_msg = ":\n" . list
		endif

		echo printf(
			\ "%s has %i watchers%s",
			\ a:key,
			\ a:watchers.watchCount,
			\ extra_msg
		\ )
	endfunction

	call api#get_watchers({watchers -> s:print_watchers(watchers)}, a:key)
endfunction

function s:assign_issue_to_sprint(key) abort
	call choose#board(
		\ {board -> choose#sprint(
			\ {sprint -> api#assign_issue_to_sprint(
				\ {-> issue_view#reload(a:key)},
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
				\ {-> issue_view#reload(a:key)},
				\ a:key,
				\ epic.id
			\ )},
			\ board.id
		\ )}
	\ )
endfunction

function s:link_issue(key, ...) abort
	let link_key = a:0 > 0 ? a:000[0] : input("Link to: ")
	call choose#link_type(
		\ {link -> api#link_issue(
			\ {-> issue_view#reload(a:key)},
			\ link[2] == "outward" ? link_key : a:key,
			\ link[2] == "outward" ? a:key : link_key,
			\ link[3],
		\ )}
	\ )
endfunction

function s:change_issue_type(key) abort
	call api#get_issue_edit_metadata(
		\ {meta -> (has_key(meta.fields, "issuetype") && has_key(meta.fields.issuetype, "allowedValues"))
			\ ? choose#issue_type(
				\ {type -> api#set_issue_type(
					\ {-> issue_view#reload(a:key)},
					\ a:key,
					\ type.id
				\ )},
				\ meta.fields.issuetype.allowedValues
			\ )
			\ : utils#echo("No available issue types")
		\ },
		\ a:key
	\ )
endfunction

function s:key_under_cursor() abort
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

function s:summarise_issue_echo(issue) abort
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

function s:summarise_issue(issue) abort
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
	let key = s:key_under_cursor()
	if ! empty(key)
		call api#get_issue({d -> s:summarise_issue_echo(d)}, key, 0)
	endif
endfunction

function Foldtext() abort
	let line = getline(v:foldstart)
	let line = substitute(line,'^-- \|⟪⟪$', '', 'g')
	return line . '↴'
endfunction

function issue_view#setup() abort
	syntax clear
	syntax sync fromstart

	setlocal bufhidden=unload
	setlocal buftype=acwrite
	setlocal colorcolumn=0
	setlocal conceallevel=3
	setlocal fillchars+=fold:\ 
	setlocal foldmethod=marker
	setlocal foldmarker=⟪⟪,⟫⟫
	setlocal foldtext=Foldtext()
	setlocal formatoptions=roqn
	setlocal nolist
	setlocal nomodified
	setlocal nonumber
	setlocal noswapfile
	setlocal nowrap
	"setlocal signcolumn=yes:1
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
	syntax match JiraCommentHeader '^\n❱ [a-zA-Z0-9 :-]\+ ago$'

	syntax region JiraCommentEntry
		\ start='^-- Add comment: ⟪⟪$'
		\ start='^-- Edit comment: ⟪⟪$'
		\ end='^-- End of comment ⟫⟫$'

	nnoremap <buffer> <silent> <CR> :call <SID>preview_issue_under_cursor()<CR>
	nnoremap <buffer> <silent> <C-]> :call issue_view#load(<SID>key_under_cursor())<CR>
	nnoremap <buffer> <silent> q :q!<CR>

	function! s:complete_transition(A, L, P) abort
		return join(map(copy(b:jira_issue.transitions), {k,v -> v.name}), "\n")
	endfunction

	command! -buffer -bar -nargs=0 JiraEditComment :call <SID>edit_comment(b:jira_issue)
	command! -buffer -bar -nargs=0 JiraEditSummary :call <SID>edit_summary(b:jira_issue)
	command! -buffer -bar -nargs=0 JiraClaim :call <SID>do_claim(b:jira_issue.key)
	command! -buffer -bar -nargs=0 JiraStart :call <SID>do_start(b:jira_issue)
	command! -buffer -bar -nargs=0 JiraWatch :call <SID>do_watch(b:jira_issue.key)
	command! -buffer -bar -nargs=0 JiraWatchers :call <SID>list_watchers(b:jira_issue.key)
	command! -buffer -bar -nargs=?
		\ -complete=custom,<SID>complete_transition
		\ JiraTransition :call <SID>do_transition(b:jira_issue, <f-args>)
	command! -buffer -bar -nargs=0 JiraAssignToSprint :call <SID>assign_issue_to_sprint(b:jira_issue.key)
	command! -buffer -bar -nargs=? JiraLink :call <SID>link_issue(b:jira_issue.key, <f-args>)
	command! -buffer -bar -nargs=0 JiraChangeType :call <SID>change_issue_type(b:jira_issue.key)
	command! -buffer -bar -nargs=0 JiraAssignToEpic :call <SID>assign_issue_to_epic(b:jira_issue.key)
	command! -buffer -bar -nargs=0 JiraUpdateUserCache :unlet! g:jira_users | call api#get_users()
	command! -buffer -bar -nargs=0 JiraViewRaw :exe "edit " . utils#cache_file(b:jira_issue.key . ".json")
endfunction

function issue_view#open(key) abort
	execute printf("belowright %.0fsplit", winheight(0) * 0.7)
	call issue_view#load(a:key)
endfunction

function issue_view#toggle(key) abort
	let cur_win_id = win_getid()
	let wininfo = getwininfo()
	if len(wininfo) < 2
		" enable issue view
		call issue_view#open(a:key)
		call win_gotoid(cur_win_id)
		return
	endif

	" disable issue view
	call win_gotoid(g:jira_list_win)
	only
endfunction

" vim: fdm=manual
