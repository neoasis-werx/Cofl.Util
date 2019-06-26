using namespace System
using namespace System.Collections.Generic
using namespace System.IO
using namespace System.Text.RegularExpressions

<#
.SYNOPSIS
Enumerates files using .gitignore-like filters.

.DESCRIPTION
Get-FilteredChildItem uses flat-file filters to enumerate files in directory hierarchies similar to
.gitignore files. A best-effort attempt is made to be compatible with the syntax of .gitignore files,
which can be read online [here](https://git-scm.com/docs/gitignore#_pattern_format).

.EXAMPLE
PS C:\> Get-FilteredChildItem -Path $Path -IgnoreFileName .gitignore

Lists files under the directory $Path that aren't excluded by patterns declared in files with the name .gitignore.
#>
function Get-FilteredChildItem
{
    [CmdletBinding(DefaultParameterSetName='Default')]
    PARAM (
        # A path and an ignore file name are mandatory, but to make things nice you can give it paths on the pipeline.
        [Parameter(Mandatory=$true,ValueFromPipeline=$true,Position=0)]
            # The path to list from.
            [FileInfo]$Path,
        [Parameter(Mandatory=$true)]
            # The name of the ignore files.
            [string]$IgnoreFileName,
        [Parameter(ParameterSetName='ListDirectories')]
            # Emit the names of the directories, instead of the files. Directory paths are guaranteed to be unique.
            [switch]$Directory,
        [Parameter(ParameterSetName='Default')]
            # Include the ignore files in the listing, unless explicitly ignored by a filter.
            [switch]$IncludeIgnoreFiles
    )

    begin
    {
        # Match any line that is empty, whitespace, or where the first non-whitespace character is #
        [regex]$CommentLine = [regex]::new('^\s*(?:#.*)?$')
        # Match any whitespace at the end of a line that doesn't follow a backslash
        [regex]$TrailingWhitespace = [regex]::new('(?:(?<!\\)\s)+$')
        # Match any backslash at the start of the line, or before a whitespace character.
        [regex]$UnescapeCharacters = [regex]::new('^\\|\\(?=\s)')
        # Unescape characters used in patterns
        [regex]$UnescapePatternCharacters = [regex]::new('^\\(?=[\[\\\*\?])')
        # Match glob patterns
        [regex]$GlobPatterns = [regex]::new('(?<!\\)\[(?<set>[^/]+)\]|(?<glob>/\*\*)|(?<star>(?<!\\)\*)|(?<any>(?<!\\)\?)|(?<text>(?:[^/?*[]|(?<=\\)[?*[])+)')
    }

    process
    {
        [Stack[DirectoryInfo]]$DirectoryStack = [Stack[DirectoryInfo]]::new()
        [LinkedList[Tuple[bool,bool,regex]]]$IgnoreRules = [LinkedList[Tuple[bool,bool,regex]]]::new()
        # This dictionary is also used as a visited tracker. The second time a directory is seen, its
        # added ignore rules are popped from the above list.
        [Dictionary[string,uint32]]$IgnoreRulePerDirectoryCounts = [Dictionary[string,uint32]]::new()
        [Stack[DirectoryInfo]]$ReverseDirectoryStack = [Stack[DirectoryInfo]]::new()
        [Queue[FileInfo]]$FileQueue = [Queue[FileInfo]]::new()
        [string]$BasePath = (Get-Item -LiteralPath $Path.FullName).FullName.Replace('\', '/').TrimEnd('/')
        $DirectoryStack.Push([DirectoryInfo]::new($BasePath))
        [int]$BasePathLength = $BasePath.Length
        $BasePath = [regex]::Escape($BasePath)

        while($DirectoryStack.Count -gt 0)
        {
            [DirectoryInfo]$Top = $DirectoryStack.Pop()
            if($IgnoreRulePerDirectoryCounts.ContainsKey($Top.FullName))
            {
                # If this is the second time we've seen this node, remove the rules
                # for this directory from the list. Then, remove this directory from
                # the map (we won't see it again, so save some memory).
                [uint32]$IgnoreRuleCount = $IgnoreRulePerDirectoryCounts[$Top.FullName]
                while($IgnoreRuleCount -gt 0)
                {
                    $IgnoreRules.RemoveFirst()
                    $IgnoreRuleCount -= 1
                }
                [void]$IgnoreRulePerDirectoryCounts.Remove($Top.FullName)
                continue
            }
            try
            {
                # For each file or directory...
                [IEnumerator[FileSystemInfo]]$Entries = $Top.EnumerateFileSystemInfos().GetEnumerator()
                [uint32]$IgnoreRuleCount = 0
                while($Entries.MoveNext())
                {
                    [FileSystemInfo]$Item = $Entries.Current
                    if($Item.Attributes.HasFlag([FileAttributes]::Directory))
                    {
                        # If we found a directory, add it to the revere stack. The reverse
                        # stack is used to fix the processing order of the main stack
                        # (directories are popped in reverse order off this stack, and
                        # added correctly to the main stack below).
                        $ReverseDirectoryStack.Push([DirectoryInfo]$Item)
                    } elseif($Item.Name -ne $IgnoreFileName)
                    {
                        # Otherwise, if we found a file (that isn't the ignore file), add it
                        # to the queue of files to be processed.
                        $FileQueue.Enqueue([FileInfo]$Item)
                    } else
                    {
                        # We have a file with the same name as the ignore file.
                        if($IncludeIgnoreFiles)
                        {
                            $FileQueue.Enqueue([FileInfo]$Item)
                        }
                        try
                        {
                            [StreamReader]$Reader = [StreamReader]::new(([FileInfo]$Item).OpenRead())
                            # We can't give $Line the type string, even though that's what it is,
                            # because PowerShell won't let us assign null to a string variable
                            # (it gets converted to an empty string, which is valid).
                            $Line = $null
                            while($null -ne ($Line = $Reader.ReadLine()))
                            {
                                if($CommentLine.IsMatch($Line))
                                {
                                    continue
                                }
                                [bool]$IsExcludeRule = $false
                                if($Line[0] -eq '!')
                                {
                                    $IsExcludeRule = $true
                                    $Line = $Line.Substring(1)
                                }
                                # Do an initial trim/unescape/prefix/suffix
                                [string]$Base = $Top.FullName.Substring($BasePathLength).Replace('\', '/')
                                $Line = $UnescapeCharacters.Replace($TrailingWhitespace.Replace($Line, ''), '')
                                [bool]$IsDirectoryRule = $Line[-1] -eq '/'
                                $Line = if($Line[0] -eq '/') { "$Base$Line" } else { "$Base/**/$Line" }
                                $Line = if($IsDirectoryRule) { $Line } else { "$Line/**" }

                                # Transform the cleaned pattern into a regex and add it to the ignore rule list
                                [void]$IgnoreRules.AddFirst([Tuple[bool,bool,regex]]::new($IsExcludeRule, $IsDirectoryRule, [regex]::new("^$BasePath$($GlobPatterns.Replace($Line, [MatchEvaluator]{
                                    param([Match]$Match)

                                    # In this delegate, we replace the various glob patterns with regex patterns, and escape all other text (except /).
                                    if($Match.Groups['set'].Success)
                                    {
                                        [string]$Escaped = [regex]::Escape($Match.Groups['set'].Value)
                                        if($Escaped[0] -eq '!')
                                        {
                                            $Escaped = '^' + $Escaped.Substring(1)
                                        }
                                        return "[$Escaped]"
                                    } elseif($Match.Groups['glob'].Success)
                                    {
                                        return '(/.*)?'
                                    } elseif($Match.Groups['star'].Success)
                                    {
                                        return '[^/]*'
                                    } elseif($Match.Groups['any'].Success)
                                    {
                                        return '.'
                                    } else
                                    {
                                        return [regex]::Escape($UnescapePatternCharacters.Replace($Match.Groups['text'].Value, ''))
                                    }
                                }))$")))
                                $IgnoreRuleCount += 1
                            }
                        } finally
                        {
                            # A finally block always runs.
                            # This one is used to dispose of the stream reader and its underlying stream.
                            # In C#, this would be a "using" pattern:
                            #
                            #     using(var reader = new StreamReader(item.OpenRead())) { ... }
                            #
                            if($null -ne $Reader)
                            {
                                $Reader.Close()
                                $Reader = $null
                            }
                        }
                    }
                }
                # For each directory in our stack from where we are now up to the root of the search,
                # we keep track of how many rules were added in that directory. We then put the
                # current directory back onto the stack, so we'll see it a second time after all of
                # its children have been processed. That time around, we'll remove this many rules
                # from the start of the rule list, and stop.
                $IgnoreRulePerDirectoryCounts[$Top.FullName] = $IgnoreRuleCount
                $DirectoryStack.Push($Top)

                [IEnumerator[Tuple[bool,bool,regex]]]$IgnoreRule = $IgnoreRules.GetEnumerator()
                # Empty the reverse stack onto the normal stack. This fixes the processing
                # order.
                # This is a named loop. Naming the loop lets us continue this loop
                # from inside the inner loop.
                :DirectoryLoop
                while($ReverseDirectoryStack.Count -gt 0)
                {
                    # .Reset() lets us re-use the same iterator over and over again
                    $IgnoreRule.Reset()
                    $Top = $ReverseDirectoryStack.Pop()
                    while($IgnoreRule.MoveNext())
                    {
                        [bool]$IsMatch = $IgnoreRule.Current.Item3.IsMatch($Top.FullName.Replace('\', '/')+'/')
                        if($IsMatch)
                        {
                            # If this is an exclusion/allow rule, add the directory to the stack
                            if($IgnoreRule.Current.Item1)
                            {
                                $DirectoryStack.Push($Top)
                            }
                            # But always continue to the next directory.
                            continue DirectoryLoop
                        }
                    }
                    $DirectoryStack.Push($Top)
                }

                :FileLoop
                while($FileQueue.Count -gt 0)
                {
                    # .Reset() lets us re-use the same iterator over and over again
                    $IgnoreRule.Reset()
                    [FileInfo]$FileItem = $FileQueue.Dequeue()
                    # For .gitignore's, the last rule that applies is the one
                    # that takes precedence. The rules are stored in reverse
                    # order of their declaration, so we just need to traverse
                    # forward through the list.
                    while($IgnoreRule.MoveNext())
                    {
                        if($IgnoreRule.Current.Item2)
                        {
                            # Skip over directory rules, those only apply to directories.
                            continue
                        }
                        [bool]$IsMatch = $IgnoreRule.Current.Item3.IsMatch($FileItem.FullName.Replace('\', '/'))
                        if($IsMatch)
                        {
                            # If this is an exclusion/allow rule, write out the file to the pipeline
                            if($IgnoreRule.Current.Item1)
                            {
                                Write-Output -InputObject $FileItem
                            }
                            # But always continue to the next file.
                            continue FileLoop
                        }
                    }

                    # At this point, all the rules have been processed, and the file has been
                    # neither excluded/allowed nor ignored. Write it to the pipeline before continuing.
                    Write-Output -InputObject $FileItem
                }
            } finally
            {
                # A finally block always runs.
                # This one is used to dispose of our iterators if they still exist.
                if($null -ne $Entries)
                {
                    $Entries.Dispose()
                    $Entries = $null
                }
                if($null -ne $IgnoreRule)
                {
                    $IgnoreRule.Dispose()
                    $IgnoreRule = $null
                }
            }
        }
    }
}
