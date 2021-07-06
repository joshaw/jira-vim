" https://developer.atlassian.com/cloud/jira/platform/rest/v2/
" https://docs.atlassian.com/jira-software/REST/7.3.1/#agile/1.0/

augroup Jira
	autocmd!
	autocmd BufReadCmd jira://* :call issue_view#read_cmd(expand('<afile>'))
	autocmd BufWriteCmd jira://* :call issue_view#post_comment(b:jira_issue.key)
augroup END

"nnoremap <silent> <tab> :wincmd w<CR>
nnoremap <silent> R :unlet! b:jira_comment_id <bar> call issue_view#reload(utils#get_key())<CR>
nnoremap <silent> gx :call system(["xdg-open", utils#get_issue_url(utils#get_key())])<CR>
nnoremap <silent> zv :call issue_view#toggle(utils#get_key())<CR>

command! -nargs=0 JiraToggleIssueView :call issue_view#toggle(utils#get_key())
command! -nargs=* Jira :call Jira(<q-args>)

function Jira(...) abort
	for progname in ["curl", "fmt"]
		if ! executable(progname)
			echoerr "Required executable, " . progname . ", was not found"
			return
		endif
	endfor

	" List Window
	let list_buf = list_view#the()
	let list_win = win_findbuf(list_buf)
	if empty(list_win)
		let list_win = [win_getid()]
		execute "buffer " . list_buf
	else
		call win_gotoid(list_win[0])
	endif
	let g:jira_list_win = win_getid()
	call list_view#setup()

	" Determine query to use
	let query = a:0 >= 1 ? a:1 : ""
	let options = a:0 >= 2 ? a:2 : {}

	if empty(query)
		let query = utils#get_saved_queries().default
	elseif has_key(utils#get_saved_queries(), query)
		let query = utils#get_saved_queries()[a:1]
	elseif query =~# '^\u\+-\d\+$'
		let query = "key = " . query
		call issue_view#load_previous_window(query)
	endif

	if get(g:, "jira_open_issue_view_by_default", 0)
		call issue_view#toggle("summary")
	endif

	function! s:search_callback(data) abort closure
		call list_view#set(query, a:data)
		let g:jira_query_data = a:data

		let cache_file = utils#cache_file("search_results.json")
		call writefile([json_encode(a:data)], cache_file, "S")

		let summary_buf = bufnr("jira://summary")
		if summary_buf > 0 && ! empty(win_findbuf(summary_buf))
			call issue_view#set_summary(a:data, summary_buf)
		endif
	endfunction

	call api#search({d -> s:search_callback(d)}, query, options)
endfunction
